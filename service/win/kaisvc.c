/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * kaisvc.exe: Kai Watch for Windows. A LocalSystem service that watches what
 * agent processes do on the network (and, when watch_files is on, which
 * protected files they open) through ETW, and records it with libkai's own
 * audit writer, as the macOS Internet wall does in Watch mode. It never
 * blocks anything: Watch is observation; the hooks are what stop things.
 *
 * Privileged code stays small: no UI, no model, no policy writes of its own.
 * It reads the signed-in user's policy, writes records to that user's Kai
 * folder, writes its heartbeat to %ProgramData%\Kai (only SYSTEM and
 * Administrators can write there, so an agent can't fake it), and answers a
 * named pipe (\\.\pipe\kai-watch) that only SYSTEM and the signed-in user can
 * open: status, start, stop, mode off|watch. A request to change anything
 * from a process inside an agent's tree is refused. "mode" runs
 * `kai.exe policy set egress ...` as the user, so the change goes through
 * kai.exe like every other policy change.
 *
 * usage: kaisvc                         (started by the Service Control Manager)
 *        kaisvc run                     (in this console, for testing; needs admin)
 *        kaisvc install | uninstall | start | stop
 *        kaisvc status | pipe <command> (ask the running service)
 */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <softpub.h>
#include <tlhelp32.h>
#include <userenv.h>
#include <wintrust.h>
#include <wtsapi32.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "cJSON.h"
#include "etw.h"
#include "internal.h"
#include "kai.h"
#include "kai_commit.h"
#include "platform.h"
#include "watch.h"

#define SVC_NAME L"KaiWatch"
#define SVC_DISPLAY L"Kai Watch"
#define PIPE_NAME L"\\\\.\\pipe\\kai-watch"
#define DEDUPE_TICKS (600ULL * KAI_TICKS_PER_SEC)   /* one record per agent+target per 10 min, as macOS */

/* ------------------------------------------------------------------ state */

static CRITICAL_SECTION g_cs;      /* the watch, the policy, the counters */
static CRITICAL_SECTION g_steer;   /* starting and stopping ETW (main loop and pipe) */
static kai_watch *g_w;
static kai_policy *g_pol;
static long long g_pol_mtime = -1;
static int g_console;              /* kaisvc run */
static int g_user_paused;          /* pipe "stop" until "start" or a restart */
static int g_etw_wanted, g_files_wanted;
static unsigned long g_restarts, g_resyncs, g_last_lost;
static long g_records, g_seen_files;
static HANDLE g_stop_event;
static DWORD g_user_session = (DWORD)-1;
static wchar_t g_user_sid[200];
static char g_profile[MAX_PATH * 2];
static SERVICE_STATUS_HANDLE g_ssh;
static SERVICE_STATUS g_ss;
static volatile LONG g_exit_code;

static uint64_t now_ticks(void) {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    return ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

static void say(const char *fmt, ...) {   /* console mode only: never paths or commands */
    if (!g_console) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* -------------------------------------------------------------- the user */

static char *narrow_w(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *s = n > 0 ? malloc((size_t)n) : NULL;
    if (s) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

static void set_env_folder(const wchar_t *var, REFKNOWNFOLDERID id, HANDLE tok) {
    PWSTR p = NULL;
    if (SUCCEEDED(SHGetKnownFolderPath(id, 0, tok, &p)) && p) SetEnvironmentVariableW(var, p);
    if (p) {
        char *n = narrow_w(var), *v = narrow_w(p);
        if (n && v) _putenv_s(n, v);
        free(n); free(v);
        CoTaskMemFree(p);
    }
}

/* The signed-in user's token (service) or ours (console). Caller closes. */
static HANDLE user_token(DWORD *session) {
    HANDLE tok = NULL;
    if (g_console) {
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY, &tok);
        if (session) ProcessIdToSessionId(GetCurrentProcessId(), session);
        return tok;
    }
    DWORD s = WTSGetActiveConsoleSessionId();
    if (s == 0xFFFFFFFF || !WTSQueryUserToken(s, &tok)) return NULL;
    if (session) *session = s;
    return tok;
}

static int token_sid(HANDLE tok, wchar_t *out, size_t n) {
    BYTE buf[256];
    DWORD got = 0;
    if (!GetTokenInformation(tok, TokenUser, buf, sizeof buf, &got)) return -1;
    LPWSTR s = NULL;
    if (!ConvertSidToStringSidW(((TOKEN_USER *)buf)->User.Sid, &s)) return -1;
    wcsncpy(out, s, n - 1);
    out[n - 1] = 0;
    LocalFree(s);
    return 0;
}

/* Point libkai at the signed-in user's home (kai_home() is ~/.kai and is
 * fixed for the life of this process: a different user signing in restarts
 * the service). 0 when a user is there. */
static int adopt_user(void) {
    DWORD session = 0;
    HANDLE tok = user_token(&session);
    if (!tok) return -1;
    wchar_t prof[MAX_PATH];
    DWORD n = MAX_PATH;
    int ok = GetUserProfileDirectoryW(tok, prof, &n);
    if (ok && !g_console) {
        SetEnvironmentVariableW(L"USERPROFILE", prof);
        char *p8 = narrow_w(prof);
        if (p8) { _putenv_s("USERPROFILE", p8); free(p8); }
        _putenv_s("HOME", "");
        set_env_folder(L"APPDATA", &FOLDERID_RoamingAppData, tok);
        set_env_folder(L"LOCALAPPDATA", &FOLDERID_LocalAppData, tok);
        _putenv_s("KAI_HOME", "");
        _putenv_s("KAI_POLICY", "");
    }
    if (ok) {
        char *p8 = narrow_w(prof);
        if (p8) { kai_strlcpy(g_profile, p8, sizeof g_profile); free(p8); }
        token_sid(tok, g_user_sid, sizeof g_user_sid / sizeof g_user_sid[0]);
        g_user_session = session;
    }
    CloseHandle(tok);
    return ok ? 0 : -1;
}

/* ---------------------------------------------------- %ProgramData%\Kai */

static void program_data_dir(wchar_t *out, size_t n) {
    wchar_t pd[MAX_PATH];
    if (!GetEnvironmentVariableW(L"ProgramData", pd, MAX_PATH)) wcscpy(pd, L"C:\\ProgramData");
    _snwprintf(out, n, L"%s\\Kai", pd);
    out[n - 1] = 0;
}

/* SYSTEM and Administrators full control, users read; not inherited from
 * %ProgramData% (where any user may create files). Reapplied at every start,
 * so a folder someone made earlier with their own ACL is taken back. */
static int secure_program_data(void) {
    wchar_t dir[MAX_PATH];
    program_data_dir(dir, MAX_PATH);
    PSECURITY_DESCRIPTOR sd = NULL;
    /* The service (SYSTEM) also takes ownership; an administrator's console
     * run can't name SYSTEM as owner, so it leaves the owner alone. */
    const wchar_t *sddl = g_console ? L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)"
                                    : L"O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &sd, NULL)) return -1;
    SECURITY_ATTRIBUTES sa = {sizeof sa, sd, FALSE};
    if (!CreateDirectoryW(dir, &sa) && GetLastError() != ERROR_ALREADY_EXISTS)
        say("can't create %%ProgramData%%\\Kai (error %lu)", GetLastError());
    BOOL present = FALSE, def = FALSE;
    PACL dacl = NULL;
    GetSecurityDescriptorDacl(sd, &present, &dacl, &def);
    PSID owner = NULL;
    GetSecurityDescriptorOwner(sd, &owner, &def);
    DWORD r = SetNamedSecurityInfoW(dir, SE_FILE_OBJECT,
                                    DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION |
                                        (g_console ? 0 : OWNER_SECURITY_INFORMATION),
                                    g_console ? NULL : owner, NULL, dacl, NULL);
    LocalFree(sd);
    return r == ERROR_SUCCESS ? 0 : -1;
}

static void write_atomic(const char *path, const char *text) {
    char tmp[MAX_PATH * 2];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    static int failed;   /* said once per failure streak */
    FILE *f = fopen(tmp, "wb");
    if (!f) {
        if (!failed++) say("can't write the heartbeat (errno %d)", errno);
        return;
    }
    fputs(text, f);
    fclose(f);
    wchar_t wt[MAX_PATH * 2], wp[MAX_PATH * 2];
    MultiByteToWideChar(CP_UTF8, 0, tmp, -1, wt, MAX_PATH * 2);
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wp, MAX_PATH * 2);
    if (!MoveFileExW(wt, wp, MOVEFILE_REPLACE_EXISTING)) {
        if (!failed++) say("can't replace the heartbeat (error %lu)", GetLastError());
        return;
    }
    failed = 0;
}

/* ------------------------------------------------------- signer (Authenticode) */

static const struct { const char *agent, *signer; } SIGNERS[] = {
    {"claude", "Anthropic, PBC"},
    {"codex", "OpenAI OpCo, LLC"},
    {"cursor", "Anysphere, Inc."},
};

/* The embedded Authenticode signer's name of a verified file, "" if none. */
static void file_signer(const char *path, char *out, size_t n) {
    out[0] = '\0';
    wchar_t w[MAX_PATH * 2];
    if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, w, MAX_PATH * 2)) return;
    WINTRUST_FILE_INFO fi = {sizeof fi};
    fi.pcwszFilePath = w;
    WINTRUST_DATA wd;
    memset(&wd, 0, sizeof wd);
    wd.cbStruct = sizeof wd;
    wd.dwUIChoice = WTD_UI_NONE;
    wd.fdwRevocationChecks = WTD_REVOKE_NONE;
    wd.dwUnionChoice = WTD_CHOICE_FILE;
    wd.pFile = &fi;
    wd.dwStateAction = WTD_STATEACTION_VERIFY;
    wd.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG r = WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &wd);
    if (r == ERROR_SUCCESS) {
        CRYPT_PROVIDER_DATA *pd = WTHelperProvDataFromStateData(wd.hWVTStateData);
        CRYPT_PROVIDER_SGNR *sg = pd ? WTHelperGetProvSignerFromChain(pd, 0, FALSE, 0) : NULL;
        if (sg && sg->csCertChain && sg->pasCertChain && sg->pasCertChain[0].pCert) {
            wchar_t name[256];
            if (CertGetNameStringW(sg->pasCertChain[0].pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, NULL, name, 256) > 1)
                WideCharToMultiByte(CP_UTF8, 0, name, -1, out, (int)n, NULL, NULL);
        }
    }
    wd.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &wd);
}

#define SIGNER_CACHE 128
static struct { char path[512]; char signer[128]; } g_signers[SIGNER_CACHE];
static int g_nsigners;

static const char *cached_signer(const char *path) {
    for (int i = 0; i < g_nsigners; i++)
        if (!_stricmp(g_signers[i].path, path)) return g_signers[i].signer;
    int i = g_nsigners < SIGNER_CACHE ? g_nsigners++ : (int)(GetTickCount() % SIGNER_CACHE);
    kai_strlcpy(g_signers[i].path, path, sizeof g_signers[i].path);
    file_signer(path, g_signers[i].signer, sizeof g_signers[i].signer);
    return g_signers[i].signer;
}

/* --------------------------------------------------------------- classify */

static int is_script_host(const char *image) {
    const char *b = strrchr(image, '/');
    b = b ? b + 1 : image;
    return !_stricmp(b, "node.exe") || !_stricmp(b, "bun.exe") || !_stricmp(b, "deno.exe") ||
           !_stricmp(b, "python.exe") || !_stricmp(b, "pythonw.exe");
}

/* An agent by its program path (libkai's agent list), or, for node / bun /
 * python, by its command line. The signer, when it is the agent's
 * publisher, is the identity; a path match alone still tags (the fallback). */
static int svc_classify(void *ctx, uint32_t pid, const char *image, char *agent, size_t an, char *ident, size_t in) {
    (void)ctx;
    if (!g_pol) return 0;
    int hit = kai_agent_match(g_pol, image, NULL, 0, NULL, agent, an);
    if (!hit && is_script_host(image)) {
        kai_proc pr;
        if (kai_proc_read((int)pid, &pr) == 0) {
            hit = kai_agent_match(g_pol, image, (const char *const *)pr.argv, pr.argc, NULL, agent, an);
            kai_proc_free(&pr);
        }
    }
    if (!hit) return 0;
    {
        const char *b = strrchr(image, '/');
        say("agent process: %s, pid %lu (%s)", agent, (unsigned long)pid, b ? b + 1 : image);
    }
    ident[0] = '\0';
    const char *want = NULL;
    for (size_t i = 0; i < sizeof SIGNERS / sizeof SIGNERS[0]; i++)
        if (!strcmp(SIGNERS[i].agent, agent)) want = SIGNERS[i].signer;
    if (want && !is_script_host(image)) {
        const char *s = cached_signer(image);
        if (!strcmp(s, want)) snprintf(ident, in, "%s (Authenticode)", s);
    }
    return 1;
}

/* ----------------------------------------------------------------- records */

static struct { uint32_t h; uint64_t t; } g_dedupe[4096];

static uint32_t fnv(const char *a, const char *b, const char *c) {
    uint32_t h = 2166136261u;
    for (const char *s = a; s && *s; s++) h = (h ^ (unsigned char)*s) * 16777619u;
    h = (h ^ '|') * 16777619u;
    for (const char *s = b; s && *s; s++) h = (h ^ (unsigned char)*s) * 16777619u;
    h = (h ^ '|') * 16777619u;
    for (const char *s = c; s && *s; s++) h = (h ^ (unsigned char)*s) * 16777619u;
    return h ? h : 1;
}

static int recently(const char *agent, const char *what, const char *target, uint64_t now) {
    uint32_t h = fnv(agent, what, target);
    unsigned i = h % (sizeof g_dedupe / sizeof g_dedupe[0]);
    if (g_dedupe[i].h == h && now - g_dedupe[i].t < DEDUPE_TICKS) return 1;
    g_dedupe[i].h = h;
    g_dedupe[i].t = now;
    return 0;
}

static struct { uint32_t root; uint64_t t; } g_touch[256];

/* The session is the agent process' own ("pid-<root>"), as the macOS
 * Internet wall uses when the Files wall named none. At most every 30 s. */
static void touch_session(uint32_t root, char *sid, size_t n, uint64_t now) {
    snprintf(sid, n, "pid-%lu", (unsigned long)root);
    unsigned i = root % 256;
    if (g_touch[i].root == root && now - g_touch[i].t < 30 * KAI_TICKS_PER_SEC) return;
    g_touch[i].root = root;
    g_touch[i].t = now;
    kai_session_activity_touch(sid, NULL, (long long)time(NULL));
}

static int watching(void) {
    return g_pol && kai_policy_egress_mode(g_pol) != KAI_EGRESS_OFF && !g_user_paused;
}

static void svc_on_connect(void *ctx, const kai_watch_event *e) {
    (void)ctx;
    const char *host = e->host;
    char why[256] = "";
    const char *skip = !watching() ? "not watching"
                     : kai_egress_endpoint_allowed(g_pol, host, e->ip, e->port, why, sizeof why) == 1 ? "allowed host"
                     : host && kai_agent_profile_allows(e->agent, host) == 1 ? "agent's own service"
                     : host && kai_pid_tool_allows((int)e->pid, host) == 1 ? "tool's own service"
                     : NULL;
    say("connect: %s %s %s port %d host %s (%s): %s", e->agent, e->proto, e->ip, e->port, host ? host : "-",
        e->host_from ? e->host_from : "no lookup", skip ? skip : "record");
    if (skip) return;
    char target[300], detail[600], sid[32];
    int v6 = strchr(e->ip, ':') != NULL;
    if (host) snprintf(target, sizeof target, "%s", host);
    else snprintf(target, sizeof target, v6 ? "[%s]:%d" : "%s:%d", e->ip, e->port);
    if (recently(e->agent, "connect", target, e->ts)) return;
    const char *from = !e->host_from ? ""
                     : !strcmp(e->host_from, "process") ? ""
                     : !strcmp(e->host_from, "agent") ? "; host name from the agent's own DNS lookup"
                     : "; host name from a DNS lookup on this computer, not necessarily the agent's";
    if (host && kai_host_is_telemetry(host) == 1)
        snprintf(detail, sizeof detail, "telemetry to %s (%s:%d); not asked about; seen by Kai Watch%s", host,
                 e->ip, e->port, from);
    else if (host)
        snprintf(detail, sizeof detail, "connection to %s (%s%s%s:%d, %s) is not on the allowlist; seen by Kai Watch%s",
                 host, v6 ? "[" : "", e->ip, v6 ? "]" : "", e->port, e->proto, from);
    else
        snprintf(detail, sizeof detail, "%s connection to %s%s%s:%d, host unknown; seen by Kai Watch",
                 e->proto, v6 ? "[" : "", e->ip, v6 ? "]" : "", e->port);
    touch_session(e->root_pid, sid, sizeof sid, e->ts);
    kai_denial_audit_ex("network", e->agent, "log", target, "connect", KAI_REASON_NOT_ALLOWLISTED, NULL, detail,
                        sid, e->identity && *e->identity ? e->identity : NULL);
    g_records++;
    say("recorded: %s -> %s", e->agent, target);
}

static int svc_file_protected(void *ctx, const char *agent, const char *path, char *rule, size_t n) {
    (void)ctx;
    if (!g_pol || !kai_policy_watch_files(g_pol)) return 0;
    int r = kai_path_protected_as(g_pol, agent, path, NULL, rule, n);
    if (r) say("file: %s opened a protected file (%s)", agent, rule);
    return r;
}

static void svc_on_file(void *ctx, const kai_watch_event *e) {
    (void)ctx;
    if (recently(e->agent, "open", e->path, e->ts)) return;
    char sid[32], detail[400];
    snprintf(detail, sizeof detail,
             "seen: %s, running under the agent, opened this protected file outside Kai's hooks. "
             "Kai Watch only watches: it didn't stop this, and can't tell what was read",
             e->image && *e->image ? e->image : "a program");
    touch_session(e->root_pid, sid, sizeof sid, e->ts);
    kai_denial_audit_ex("storage", e->agent, "log", e->path, "open", KAI_REASON_PROTECTED, e->rule, detail, sid,
                        e->identity && *e->identity ? e->identity : NULL);
    g_seen_files++;
}

/* ----------------------------------------------------------------- the sink */

static void sk_start(uint32_t pid, uint32_t ppid, uint64_t start, const char *image) {
    EnterCriticalSection(&g_cs);
    kai_watch_process_start(g_w, pid, ppid, start, image);
    if (g_console) {
        char a[32] = "", pa[32] = "";
        kai_watch_tagged(g_w, pid, 0, a, sizeof a);
        kai_watch_tagged(g_w, ppid, 0, pa, sizeof pa);
        const char *b = image ? strrchr(image, '/') : NULL;
        say("start: pid %lu parent %lu (%s) %s -> %s", (unsigned long)pid, (unsigned long)ppid, pa[0] ? pa : "untagged",
            b ? b + 1 : image ? image : "?", a[0] ? a : "untagged");
    }
    LeaveCriticalSection(&g_cs);
}
static void sk_stop(uint32_t pid, uint64_t start, uint64_t ts) {
    EnterCriticalSection(&g_cs);
    kai_watch_process_stop(g_w, pid, start, ts);
    LeaveCriticalSection(&g_cs);
}
static void sk_dns(uint32_t pid, uint64_t ts, const char *name, const char *results) {
    EnterCriticalSection(&g_cs);
    kai_watch_dns(g_w, pid, ts, name, results);
    LeaveCriticalSection(&g_cs);
}
static void sk_connect(uint32_t pid, uint64_t ts, const char *proto, const char *ip, int port) {
    EnterCriticalSection(&g_cs);
    kai_watch_connect(g_w, pid, ts, proto, ip, port);
    LeaveCriticalSection(&g_cs);
}
static void sk_file(uint32_t pid, uint64_t ts, const char *path) {
    EnterCriticalSection(&g_cs);
    kai_watch_file(g_w, pid, ts, path);
    LeaveCriticalSection(&g_cs);
}
static int sk_tagged(uint32_t pid) {
    EnterCriticalSection(&g_cs);
    int t = kai_watch_pid_maybe_tagged(g_w, pid);
    LeaveCriticalSection(&g_cs);
    return t;
}
static const kai_etw_sink SINK = {sk_start, sk_stop, sk_dns, sk_connect, sk_file, sk_tagged};

/* ------------------------------------------------------- process snapshot */

typedef struct { uint32_t pid, ppid; uint64_t start; char image[1100]; } snap_t;

static int by_start(const void *a, const void *b) {
    uint64_t x = ((const snap_t *)a)->start, y = ((const snap_t *)b)->start;
    return x < y ? -1 : x > y;
}

/* Every running process, oldest first, so parents are known before their
 * children: at start, and after ETW lost events. */
static void resync(void) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    int cap = 1024, n = 0;
    snap_t *v = malloc((size_t)cap * sizeof *v);
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof pe;
    for (BOOL ok = Process32FirstW(snap, &pe); ok && v; ok = Process32NextW(snap, &pe)) {
        if (n == cap) {
            snap_t *nv = realloc(v, (size_t)(cap *= 2) * sizeof *v);
            if (!nv) break;
            v = nv;
        }
        snap_t *s = &v[n];
        memset(s, 0, sizeof *s);
        s->pid = pe.th32ProcessID;
        s->ppid = pe.th32ParentProcessID;
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
        if (h) {
            FILETIME c, x, k, u;
            if (GetProcessTimes(h, &c, &x, &k, &u)) s->start = ((uint64_t)c.dwHighDateTime << 32) | c.dwLowDateTime;
            wchar_t img[MAX_PATH * 2];
            DWORD il = MAX_PATH * 2;
            if (QueryFullProcessImageNameW(h, 0, img, &il)) {
                WideCharToMultiByte(CP_UTF8, 0, img, -1, s->image, (int)sizeof s->image, NULL, NULL);
                for (char *c2 = s->image; *c2; c2++) if (*c2 == '\\') *c2 = '/';
            }
            CloseHandle(h);
        }
        n++;
    }
    CloseHandle(snap);
    if (!v) return;
    qsort(v, (size_t)n, sizeof *v, by_start);
    EnterCriticalSection(&g_cs);
    kai_watch_sync_begin(g_w);
    for (int i = 0; i < n; i++)
        kai_watch_process_start(g_w, v[i].pid, v[i].ppid, v[i].start, v[i].image[0] ? v[i].image : NULL);
    kai_watch_sync_end(g_w, now_ticks());
    LeaveCriticalSection(&g_cs);
    free(v);
}

/* ------------------------------------------------------------------ policy */

static void reload_policy(int force) {
    struct stat st;
    long long mt = stat(kai_policy_file(), &st) == 0 ? (long long)st.st_mtime : 0;
    if (!force && mt == g_pol_mtime) return;
    char err[256] = "";
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    EnterCriticalSection(&g_cs);
    kai_policy *old = g_pol;
    if (p) g_pol = p;   /* an unreadable policy keeps the last good one */
    g_pol_mtime = mt;
    LeaveCriticalSection(&g_cs);
    if (p) kai_policy_free(old);
}

/* --------------------------------------------------------------- heartbeat */

static char *status_json(void) {
    kai_etw_state es;
    kai_etw_query(&es);
    kai_watch_stats ws;
    EnterCriticalSection(&g_cs);
    kai_watch_get_stats(g_w, &ws);
    int want = watching();
    int files = g_pol && kai_policy_watch_files(g_pol);
    int pol_ok = g_pol != NULL;
    LeaveCriticalSection(&g_cs);
    char fp[16] = "";
    kai_policy_fingerprint(fp, sizeof fp);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "wall", "network");
    cJSON_AddStringToObject(o, "mode", want ? "log" : "off");
    cJSON_AddBoolToObject(o, "enforcing", 0);
    cJSON_AddBoolToObject(o, "watch_only", 1);
    cJSON_AddStringToObject(o, "platform", "windows");
    cJSON_AddStringToObject(o, "policy", fp);
    cJSON_AddStringToObject(o, "policy_state", pol_ok ? "ok" : "unreadable");
    cJSON_AddNumberToObject(o, "flows", (double)ws.connects);
    cJSON_AddNumberToObject(o, "agent_flows", (double)ws.agent_connects);
    cJSON_AddNumberToObject(o, "blocked", 0);
    cJSON_AddBoolToObject(o, "paused", g_user_paused);
    cJSON_AddNumberToObject(o, "records", (double)g_records);
    cJSON_AddNumberToObject(o, "processes", (double)ws.procs);
    cJSON_AddNumberToObject(o, "agent_processes", (double)ws.tagged);
    /* running: up and seeing events. When Watch is on but ETW isn't
     * delivering, this is false with the problem: never a fake healthy state. */
    int running = !want || es.running;
    cJSON_AddBoolToObject(o, "running", running);
    cJSON *e = cJSON_AddObjectToObject(o, "etw");
    cJSON_AddStringToObject(e, "state", es.running ? "running" : want ? "stopped" : "off");
    cJSON_AddNumberToObject(e, "events", (double)es.events);
    cJSON_AddNumberToObject(e, "events_lost", (double)es.events_lost);
    cJSON_AddNumberToObject(e, "buffers_lost", (double)es.buffers_lost);
    cJSON_AddNumberToObject(e, "restarts", (double)g_restarts);
    cJSON_AddNumberToObject(e, "resyncs", (double)g_resyncs);
    static const char *const PROV[4] = {"process", "network", "dns", "file"};
    {
        extern unsigned long g_dns_bad[4];
        cJSON *db = cJSON_AddObjectToObject(e, "dns_skipped");
        cJSON_AddNumberToObject(db, "no_status", (double)g_dns_bad[0]);
        cJSON_AddNumberToObject(db, "failed", (double)g_dns_bad[1]);
        cJSON_AddNumberToObject(db, "no_name", (double)g_dns_bad[2]);
        cJSON_AddNumberToObject(db, "no_results", (double)g_dns_bad[3]);
        extern unsigned long g_dns_status[8], g_dns_ids[3];
        cJSON_AddNumberToObject(db, "id3008", (double)g_dns_ids[0]);
        cJSON_AddNumberToObject(db, "id3018", (double)g_dns_ids[1]);
        cJSON_AddNumberToObject(db, "id3020", (double)g_dns_ids[2]);
        cJSON *ls = cJSON_AddArrayToObject(db, "last_failures");
        for (int i = 0; i < 8; i++)
            if (g_dns_status[i]) cJSON_AddItemToArray(ls, cJSON_CreateNumber((double)g_dns_status[i]));
    }
    cJSON *bp = cJSON_AddObjectToObject(e, "delivered");
    cJSON *pp = cJSON_AddObjectToObject(e, "parsed");
    for (int i = 0; i < 4; i++) {
        cJSON_AddNumberToObject(bp, PROV[i], (double)es.by_provider[i]);
        cJSON_AddNumberToObject(pp, PROV[i], (double)es.parsed[i]);
    }
    {   /* this service's own CPU time, for the budget */
        FILETIME c, x, k, u;
        if (GetProcessTimes(GetCurrentProcess(), &c, &x, &k, &u)) {
            uint64_t kt = ((uint64_t)k.dwHighDateTime << 32) | k.dwLowDateTime;
            uint64_t ut = ((uint64_t)u.dwHighDateTime << 32) | u.dwLowDateTime;
            cJSON_AddNumberToObject(o, "cpu_ms", (double)((kt + ut) / 10000));
        }
    }
    cJSON *f = cJSON_AddObjectToObject(o, "files");
    cJSON_AddBoolToObject(f, "on", files);
    cJSON_AddNumberToObject(f, "seen", (double)g_seen_files);
    cJSON_AddStringToObject(o, "problem", running ? "" : es.problem[0] ? es.problem : "ETW isn't delivering events");
    cJSON_AddStringToObject(o, "version", KAI_VERSION);
    cJSON_AddStringToObject(o, "commit", KAI_COMMIT);
    cJSON_AddNumberToObject(o, "ts", (double)time(NULL));
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return s;
}

static void write_heartbeat(void) {
    char *s = status_json();
    if (s) {
        write_atomic(kai_network_heartbeat_path(), s);
        free(s);
    }
}

/* ---------------------------------------------------------------- watching */

static ULONGLONG g_next_try;
static unsigned g_backoff = 5000;

static void stop_watching(void) {
    kai_etw_stop();
    g_etw_wanted = 0;
}

/* Start, keep or stop the ETW session to match the policy and the pipe. */
static void steer_locked(void);
static void steer(void) {
    EnterCriticalSection(&g_steer);
    steer_locked();
    LeaveCriticalSection(&g_steer);
}

static void steer_locked(void) {
    EnterCriticalSection(&g_cs);
    int want = watching();
    int files = g_pol && kai_policy_watch_files(g_pol);
    LeaveCriticalSection(&g_cs);
    kai_etw_state es;
    kai_etw_query(&es);
    if (!want) {
        if (g_etw_wanted) { say("watching off"); stop_watching(); }
        return;
    }
    if (g_etw_wanted && es.running && files == g_files_wanted) {
        unsigned long lost = es.events_lost + es.buffers_lost;
        if (lost != g_last_lost) {   /* events were lost: the tree may have holes */
            g_last_lost = lost;
            resync();
            g_resyncs++;
            say("events lost (%lu): process list resynced", lost);
        }
        g_backoff = 5000;
        return;
    }
    if (GetTickCount64() < g_next_try) return;
    if (g_etw_wanted) g_restarts++;
    int r = kai_etw_start(&SINK, files);
    g_etw_wanted = 1;
    g_files_wanted = files;
    if (r == 0) {
        resync();
        kai_etw_query(&es);
        g_last_lost = es.events_lost + es.buffers_lost;
        say("watching (files %s)", files ? "on" : "off");
    } else {
        say("ETW: %s", es.problem);
        g_next_try = GetTickCount64() + g_backoff;
        if (g_backoff < 60000) g_backoff *= 2;
    }
}

/* -------------------------------------------------------------------- pipe */

/* Run kai.exe (next to kaisvc.exe) as the signed-in user; first line of its
 * output in out. Exit code, or -1. */
static int run_kai_as_user(const wchar_t *args, char *out, size_t n) {
    out[0] = '\0';
    wchar_t exe[MAX_PATH], cmd[MAX_PATH + 200];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    wchar_t *slash = wcsrchr(exe, L'\\');
    if (!slash) return -1;
    wcscpy(slash + 1, L"kai.exe");
    _snwprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%s\" %s", exe, args);
    cmd[sizeof cmd / sizeof cmd[0] - 1] = 0;
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    HANDLE rd, wr;
    if (!CreatePipe(&rd, &wr, &sa, 0)) return -1;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW si = {sizeof si};
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = wr;
    si.hStdError = wr;
    si.hStdInput = NULL;
    PROCESS_INFORMATION pi;
    BOOL ok;
    if (g_console) {
        ok = CreateProcessW(exe, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    } else {
        HANDLE tok = user_token(NULL);
        void *env = NULL;
        if (tok) CreateEnvironmentBlock(&env, tok, FALSE);
        ok = tok && CreateProcessAsUserW(tok, exe, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                                         env, NULL, &si, &pi);
        if (env) DestroyEnvironmentBlock(env);
        if (tok) CloseHandle(tok);
    }
    CloseHandle(wr);
    if (!ok) { CloseHandle(rd); return -1; }
    char buf[2048];
    DWORD got = 0, total = 0;
    while (total < sizeof buf - 1 && ReadFile(rd, buf + total, (DWORD)(sizeof buf - 1 - total), &got, NULL) && got)
        total += got;
    buf[total] = '\0';
    CloseHandle(rd);
    DWORD code = (DWORD)-1;
    if (WaitForSingleObject(pi.hProcess, 15000) == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
    else TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    char *nl = strpbrk(buf, "\r\n");
    if (nl) *nl = '\0';
    kai_strlcpy(out, buf, n);
    return (int)code;
}

static char *reply(int ok, const char *msg) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", ok);
    if (msg) cJSON_AddStringToObject(o, ok ? "message" : "error", msg);
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return s;
}

static uint64_t process_start_time(uint32_t pid, char *image, size_t n) {
    uint64_t t = 0;
    if (image && n) image[0] = '\0';
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    FILETIME c, x, k, u;
    if (GetProcessTimes(h, &c, &x, &k, &u)) t = ((uint64_t)c.dwHighDateTime << 32) | c.dwLowDateTime;
    if (image && n) {
        wchar_t img[MAX_PATH * 2];
        DWORD il = MAX_PATH * 2;
        if (QueryFullProcessImageNameW(h, 0, img, &il)) {
            WideCharToMultiByte(CP_UTF8, 0, img, -1, image, (int)n, NULL, NULL);
            for (char *s = image; *s; s++) if (*s == '\\') *s = '/';
        }
    }
    CloseHandle(h);
    return t;
}

/* Is the pipe client an agent's, or under one? The tree may not know it yet
 * (ETW delivers start events up to a second late), so walk its real
 * ancestry from one snapshot: each ancestor must have started before its
 * child (else the parent PID was reused), and counts if the tree tags it or
 * its program is a known agent. */
static int client_is_agent(uint32_t client, char *agent, size_t n) {
    agent[0] = '\0';
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    int found = 0;
    uint32_t pid = client;
    uint64_t child_start = UINT64_MAX;
    for (int depth = 0; depth < 32 && pid > 4 && !found; depth++) {
        char image[MAX_PATH * 3];
        uint64_t st = process_start_time(pid, image, sizeof image);
        if (st && st > child_start) break;   /* not the real parent: its PID was reused */
        EnterCriticalSection(&g_cs);
        found = kai_watch_tagged(g_w, pid, 0, agent, n) ||
                (image[0] && g_pol && kai_agent_match(g_pol, image, NULL, 0, NULL, agent, n));
        LeaveCriticalSection(&g_cs);
        if (found) break;
        uint32_t parent = 0;
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
            if (pe.th32ProcessID == pid) { parent = pe.th32ParentProcessID; break; }
        if (!parent || parent == pid) break;
        if (st) child_start = st;
        pid = parent;
    }
    CloseHandle(snap);
    return found;
}

static char *handle_command(const char *line, uint32_t client) {
    if (!strcmp(line, "status")) return status_json();
    char agent[32] = "";
    int from_agent = client_is_agent(client, agent, sizeof agent);
    if (from_agent) {
        char m[160];
        snprintf(m, sizeof m, "refused: the request came from a process running under %s", agent);
        return reply(0, m);
    }
    if (!strcmp(line, "start")) {
        g_user_paused = 0;
        g_next_try = 0;
        steer();
        kai_etw_state es;
        kai_etw_query(&es);
        write_heartbeat();
        return reply(es.running || !watching(), es.running ? "watching" : es.problem[0] ? es.problem : "not watching");
    }
    if (!strcmp(line, "stop")) {
        g_user_paused = 1;
        steer();
        write_heartbeat();
        return reply(1, "paused until start, or until Kai Watch restarts");
    }
    if (!strcmp(line, "mode off") || !strcmp(line, "mode watch")) {
        char out[300];
        int rc = run_kai_as_user(!strcmp(line, "mode off") ? L"policy set egress off" : L"policy set egress log",
                                 out, sizeof out);
        reload_policy(1);
        steer();
        write_heartbeat();
        return reply(rc == 0, out[0] ? out : rc == 0 ? "done" : "kai.exe refused the change");
    }
    return reply(0, "unknown command: status, start, stop, mode off, mode watch");
}

static DWORD WINAPI pipe_thread(LPVOID arg) {
    (void)arg;
    int first = 1;
    while (WaitForSingleObject(g_stop_event, 0) == WAIT_TIMEOUT) {
        wchar_t sddl[400];
        _snwprintf(sddl, 400, L"D:P(A;;GA;;;SY)(A;;GRGW;;;%s)", g_user_sid[0] ? g_user_sid : L"SY");
        sddl[399] = 0;
        PSECURITY_DESCRIPTOR sd = NULL;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &sd, NULL)) return 1;
        SECURITY_ATTRIBUTES sa = {sizeof sa, sd, FALSE};
        HANDLE p = CreateNamedPipeW(PIPE_NAME,
                                    PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0),
                                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1,
                                    8192, 512, 0, &sa);
        LocalFree(sd);
        if (p == INVALID_HANDLE_VALUE) {
            say("pipe: error %lu", GetLastError());
            if (WaitForSingleObject(g_stop_event, 5000) != WAIT_TIMEOUT) break;
            continue;
        }
        first = 0;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof ov);
        ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        BOOL c = ConnectNamedPipe(p, &ov);
        DWORD err = c ? ERROR_PIPE_CONNECTED : GetLastError();
        if (err == ERROR_IO_PENDING) {
            HANDLE w[2] = {ov.hEvent, g_stop_event};
            if (WaitForMultipleObjects(2, w, FALSE, INFINITE) != WAIT_OBJECT_0) {
                CancelIo(p);
                CloseHandle(ov.hEvent);
                CloseHandle(p);
                break;
            }
            err = ERROR_PIPE_CONNECTED;
        }
        if (err == ERROR_PIPE_CONNECTED) {
            char line[256];
            DWORD got = 0;
            ResetEvent(ov.hEvent);
            BOOL r = ReadFile(p, line, sizeof line - 1, &got, &ov);
            if (!r && GetLastError() == ERROR_IO_PENDING) {
                if (WaitForSingleObject(ov.hEvent, 2000) == WAIT_OBJECT_0) GetOverlappedResult(p, &ov, &got, FALSE);
                else { CancelIo(p); got = 0; }
            }
            line[got] = '\0';
            char *nl = strpbrk(line, "\r\n");
            if (nl) *nl = '\0';
            ULONG client = 0;
            GetNamedPipeClientProcessId(p, &client);
            char *ans = got ? handle_command(line, (uint32_t)client) : NULL;
            if (ans) {
                DWORD put = 0;
                size_t l = strlen(ans);
                ResetEvent(ov.hEvent);
                if (!WriteFile(p, ans, (DWORD)l, &put, &ov) && GetLastError() == ERROR_IO_PENDING)
                    if (WaitForSingleObject(ov.hEvent, 2000) != WAIT_OBJECT_0) CancelIo(p);
                FlushFileBuffers(p);
                free(ans);
            }
            DisconnectNamedPipe(p);
        }
        CloseHandle(ov.hEvent);
        CloseHandle(p);
    }
    return 0;
}

/* -------------------------------------------------------------- main loop */

static int run_watch(void) {
    InitializeCriticalSection(&g_cs);
    InitializeCriticalSection(&g_steer);
    kai_watch_ops ops = {NULL, svc_classify, svc_on_connect, svc_file_protected, svc_on_file};
    g_w = kai_watch_new(&ops);
    if (!g_w) return 1;
    secure_program_data();
    /* wait for someone to sign in: records go to their Kai folder */
    while (adopt_user() != 0)
        if (WaitForSingleObject(g_stop_event, 5000) != WAIT_TIMEOUT) return 0;
    reload_policy(1);
    HANDLE pt = CreateThread(NULL, 0, pipe_thread, NULL, 0, NULL);
    say("Kai Watch %s (%s): watching for %s", KAI_VERSION, KAI_COMMIT, g_console ? "this console's user" : "the signed-in user");
    unsigned tick = 0;
    for (;;) {
        if (tick % 5 == 0) {
            reload_policy(tick % 30 == 0);
            steer();
            write_heartbeat();
        }
        if (tick % 30 == 29) {
            EnterCriticalSection(&g_cs);
            kai_watch_gc(g_w, now_ticks());
            LeaveCriticalSection(&g_cs);
        }
        tick++;
        if (WaitForSingleObject(g_stop_event, 1000) != WAIT_TIMEOUT) break;
    }
    stop_watching();
    write_heartbeat();   /* "off": not watching any more */
    if (pt) { WaitForSingleObject(pt, 3000); CloseHandle(pt); }
    return (int)g_exit_code;
}

/* ----------------------------------------------------------------- service */

static void report(DWORD state, DWORD code, DWORD wait) {
    g_ss.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_ss.dwCurrentState = state;
    g_ss.dwWin32ExitCode = code;
    g_ss.dwWaitHint = wait;
    g_ss.dwControlsAccepted = state == SERVICE_START_PENDING ? 0
                                                             : SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN |
                                                                   SERVICE_ACCEPT_SESSIONCHANGE;
    SetServiceStatus(g_ssh, &g_ss);
}

static DWORD WINAPI handler(DWORD ctl, DWORD type, LPVOID data, LPVOID ctx) {
    (void)ctx;
    switch (ctl) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
        report(SERVICE_STOP_PENDING, NO_ERROR, 5000);
        SetEvent(g_stop_event);
        return NO_ERROR;
    case SERVICE_CONTROL_SESSIONCHANGE:
        if (type == WTS_SESSION_LOGON || type == WTS_CONSOLE_CONNECT) {
            WTSSESSION_NOTIFICATION *n = data;
            /* someone else at the console: restart (the SCM restarts us), so
             * libkai points at their home */
            if (n && g_user_session != (DWORD)-1 && n->dwSessionId != g_user_session) {
                InterlockedExchange(&g_exit_code, 1);
                SetEvent(g_stop_event);
            }
        }
        return NO_ERROR;
    case SERVICE_CONTROL_INTERROGATE:
        return NO_ERROR;
    }
    return ERROR_CALL_NOT_IMPLEMENTED;
}

static void WINAPI service_main(DWORD argc, LPWSTR *argv) {
    (void)argc; (void)argv;
    g_ssh = RegisterServiceCtrlHandlerExW(SVC_NAME, handler, NULL);
    if (!g_ssh) return;
    report(SERVICE_START_PENDING, NO_ERROR, 10000);
    g_stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    report(SERVICE_RUNNING, NO_ERROR, 0);
    int rc = run_watch();
    /* a non-zero exit makes the SCM's failure actions restart us */
    report(SERVICE_STOPPED, rc ? ERROR_SERVICE_SPECIFIC_ERROR : NO_ERROR, 0);
}

static BOOL WINAPI console_ctrl(DWORD t) {
    (void)t;
    SetEvent(g_stop_event);
    return TRUE;
}

/* ----------------------------------------------------- install / control */

static int svc_install(void) {
    wchar_t exe[MAX_PATH], cmd[MAX_PATH + 4];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    _snwprintf(cmd, MAX_PATH + 4, L"\"%s\"", exe);
    cmd[MAX_PATH + 3] = 0;
    SC_HANDLE m = OpenSCManagerW(NULL, NULL, SC_MANAGER_CREATE_SERVICE);
    if (!m) { fprintf(stderr, "kaisvc install: needs an administrator (error %lu)\n", GetLastError()); return 1; }
    SC_HANDLE s = CreateServiceW(m, SVC_NAME, SVC_DISPLAY, SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS,
                                 SERVICE_AUTO_START, SERVICE_ERROR_NORMAL, cmd, NULL, NULL, NULL, NULL, NULL);
    if (!s && GetLastError() == ERROR_SERVICE_EXISTS) s = OpenServiceW(m, SVC_NAME, SERVICE_ALL_ACCESS);
    if (!s) { fprintf(stderr, "kaisvc install: error %lu\n", GetLastError()); CloseServiceHandle(m); return 1; }
    SERVICE_DESCRIPTIONW d = {L"Watches which hosts AI coding agents connect to and records it for Kai. "
                              L"Observation only: it doesn't block anything."};
    ChangeServiceConfig2W(s, SERVICE_CONFIG_DESCRIPTION, &d);
    SC_ACTION acts[3] = {{SC_ACTION_RESTART, 5000}, {SC_ACTION_RESTART, 5000}, {SC_ACTION_RESTART, 30000}};
    SERVICE_FAILURE_ACTIONSW fa = {86400, NULL, NULL, 3, acts};
    ChangeServiceConfig2W(s, SERVICE_CONFIG_FAILURE_ACTIONS, &fa);
    SERVICE_FAILURE_ACTIONS_FLAG ff = {TRUE};
    ChangeServiceConfig2W(s, SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, &ff);
    SERVICE_SID_INFO sid = {SERVICE_SID_TYPE_UNRESTRICTED};
    ChangeServiceConfig2W(s, SERVICE_CONFIG_SERVICE_SID_INFO, &sid);
    printf("Kai Watch service installed (starts with Windows).\n");
    CloseServiceHandle(s);
    CloseServiceHandle(m);
    return 0;
}

static int svc_control(int start) {
    SC_HANDLE m = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    SC_HANDLE s = m ? OpenServiceW(m, SVC_NAME, SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS) : NULL;
    if (!s) {
        fprintf(stderr, "kaisvc: can't open the service (error %lu)\n", GetLastError());
        if (m) CloseServiceHandle(m);
        return 1;
    }
    int rc = 0;
    SERVICE_STATUS st;
    if (start) {
        if (!StartServiceW(s, 0, NULL) && GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) rc = 1;
    } else if (!ControlService(s, SERVICE_CONTROL_STOP, &st) && GetLastError() != ERROR_SERVICE_NOT_ACTIVE) {
        rc = 1;
    }
    for (int i = 0; i < 100 && QueryServiceStatus(s, &st); i++) {
        if (st.dwCurrentState == (start ? SERVICE_RUNNING : SERVICE_STOPPED)) break;
        Sleep(100);
    }
    if (rc) fprintf(stderr, "kaisvc %s: error %lu\n", start ? "start" : "stop", GetLastError());
    CloseServiceHandle(s);
    CloseServiceHandle(m);
    return rc;
}

static int svc_uninstall(void) {
    svc_control(0);
    SC_HANDLE m = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    SC_HANDLE s = m ? OpenServiceW(m, SVC_NAME, DELETE) : NULL;
    int rc = 0;
    if (!s || !DeleteService(s)) {
        DWORD e = GetLastError();
        if (e != ERROR_SERVICE_DOES_NOT_EXIST) { fprintf(stderr, "kaisvc uninstall: error %lu\n", e); rc = 1; }
    }
    if (s) CloseServiceHandle(s);
    if (m) CloseServiceHandle(m);
    wchar_t dir[MAX_PATH], f[MAX_PATH + 40];
    program_data_dir(dir, MAX_PATH);
    _snwprintf(f, MAX_PATH + 40, L"%s\\network-health.json", dir);
    DeleteFileW(f);
    RemoveDirectoryW(dir);   /* only if empty */
    if (!rc) printf("Kai Watch service removed.\n");
    return rc;
}

/* Ask the running service (kaisvc status, kaisvc pipe <command>). */
static int pipe_ask(const char *cmd) {
    HANDLE p = INVALID_HANDLE_VALUE;
    for (int i = 0; i < 20; i++) {
        p = CreateFileW(PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (p != INVALID_HANDLE_VALUE || GetLastError() != ERROR_PIPE_BUSY) break;
        WaitNamedPipeW(PIPE_NAME, 500);
    }
    if (p == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Kai Watch isn't running (error %lu)\n", GetLastError());
        return 2;
    }
    DWORD put = 0, got = 0;
    WriteFile(p, cmd, (DWORD)strlen(cmd), &put, NULL);
    WriteFile(p, "\n", 1, &put, NULL);
    char buf[8192];
    DWORD total = 0;
    while (total < sizeof buf - 1 && ReadFile(p, buf + total, (DWORD)(sizeof buf - 1 - total), &got, NULL) && got)
        total += got;
    buf[total] = '\0';
    CloseHandle(p);
    printf("%s\n", buf);
    return total ? 0 : 1;
}

int main(int argc, char **argv) {
    kai_plat_init();
    const char *c = argc > 1 ? argv[1] : NULL;
    if (!c) {
        SERVICE_TABLE_ENTRYW t[] = {{(LPWSTR)SVC_NAME, service_main}, {NULL, NULL}};
        if (StartServiceCtrlDispatcherW(t)) return 0;
        fprintf(stderr, "kaisvc is the Kai Watch service. usage: kaisvc run | install | uninstall | start | stop | "
                        "status | pipe <command>\n");
        return 1;
    }
    if (!strcmp(c, "run")) {
        g_console = 1;
        g_stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
        SetConsoleCtrlHandler(console_ctrl, TRUE);
        return run_watch();
    }
    if (!strcmp(c, "install")) return svc_install();
    if (!strcmp(c, "uninstall")) return svc_uninstall();
    if (!strcmp(c, "start")) return svc_control(1);
    if (!strcmp(c, "stop")) return svc_control(0);
    if (!strcmp(c, "status")) return pipe_ask("status");
    if (!strcmp(c, "pipe") && argc > 2) {
        char cmd[256] = "";
        size_t o = 0;
        for (int i = 2; i < argc && o < sizeof cmd - 1; i++)
            o += (size_t)snprintf(cmd + o, sizeof cmd - o, "%s%s", i > 2 ? " " : "", argv[i]);
        return pipe_ask(cmd);
    }
    if (!strcmp(c, "version")) { printf("kaisvc %s · commit %s\n", KAI_VERSION, KAI_COMMIT); return 0; }
    fprintf(stderr, "usage: kaisvc run | install | uninstall | start | stop | status | pipe <command> | version\n");
    return 1;
}
