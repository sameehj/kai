/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Who is this process? Reads a process's executable, arguments, parent and
 * (on macOS) code-signing Team ID, and decides whether it is an agent or runs
 * under one. The network extension uses this to apply the egress wall only to
 * agent process trees; everything else on the machine is left alone.
 */
#include "internal.h"
#include "platform.h"

#include <fnmatch.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <mach/message.h>   /* audit_token_t */
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <time.h>
#else
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#endif

void kai_proc_free(kai_proc *pr) {
    for (int i = 0; i < pr->argc; i++) free(pr->argv[i]);
    free(pr->argv);
    pr->argv = NULL;
    pr->argc = 0;
}

static void push_arg(kai_proc *pr, const char *s, size_t n) {
    char **nv = realloc(pr->argv, (size_t)(pr->argc + 1) * sizeof *nv);
    if (!nv) return;
    pr->argv = nv;
    char *a = malloc(n + 1);
    if (!a) return;
    memcpy(a, s, n);
    a[n] = '\0';
    pr->argv[pr->argc++] = a;
}

#ifdef __APPLE__

static void read_team(int pid, char *team, size_t teamlen) {
    team[0] = '\0';
    CFNumberRef cfpid = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = {kSecGuestAttributePid};
    const void *vals[] = {cfpid};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code) == errSecSuccess) {
        CFDictionaryRef info = NULL;
        if (SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSSigningInformation,
                                          &info) == errSecSuccess && info) {
            CFStringRef t = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
            if (t) CFStringGetCString(t, team, (CFIndex)teamlen, kCFStringEncodingUTF8);
            CFRelease(info);
        }
        CFRelease(code);
    }
    CFRelease(attrs);
    CFRelease(cfpid);
}

static int proc_read_impl(int pid, kai_proc *out, int want_team) {
    memset(out, 0, sizeof *out);
    out->pid = pid;
    struct proc_bsdinfo bi;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi) return -1;
    out->ppid = (int)bi.pbi_ppid;
    if (proc_pidpath(pid, out->exe, sizeof out->exe) <= 0) out->exe[0] = '\0';

    /* KERN_PROCARGS2: int argc, exec path, NUL padding, then argv strings */
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t sz = 0;
    if (sysctl(mib, 3, NULL, &sz, NULL, 0) == 0 && sz > sizeof(int)) {
        char *buf = malloc(sz);
        if (buf && sysctl(mib, 3, buf, &sz, NULL, 0) == 0 && sz > sizeof(int)) {
            int argc;
            memcpy(&argc, buf, sizeof argc);
            char *p = buf + sizeof argc, *end = buf + sz;
            while (p < end && *p) p++;  /* exec path */
            while (p < end && !*p) p++; /* padding */
            for (int i = 0; i < argc && p < end; i++) {
                size_t n = strnlen(p, (size_t)(end - p));
                push_arg(out, p, n);
                p += n + 1;
            }
        }
        free(buf);
    }
    /* The code-signing lookup is the expensive part (SecCode verification). Skip
     * it when the caller does not need the Team ID -- the session scan matches
     * agents by exe/arg and would otherwise pay it for every process. */
    if (want_team) read_team(pid, out->team, sizeof out->team);
    return 0;
}

int kai_proc_read(int pid, kai_proc *out) { return proc_read_impl(pid, out, 1); }
int kai_proc_read_fast(int pid, kai_proc *out) { return proc_read_impl(pid, out, 0); }

/* Identify an XPC caller from its audit token (Step 3). The token, not a pid,
 * is the trustworthy identity: it can't be recycled under us. We validate the
 * caller's dynamic signature (anchored to Apple) and read its Team ID, signing
 * id, and pid. Returns 1 if the signature is valid, 0 otherwise. All SecCode
 * use stays here in C; Swift just hands over the token bytes. */
int kai_audit_token_identity(const void *tokbytes, size_t toklen, char *team, size_t tlen,
                             char *signid, size_t slen, int *pid) {
    if (team && tlen) team[0] = '\0';
    if (signid && slen) signid[0] = '\0';
    if (pid) *pid = -1;
    if (!tokbytes || toklen != sizeof(audit_token_t)) return 0;
    audit_token_t tok;
    memcpy(&tok, tokbytes, sizeof tok);
    /* audit_token_to_pid() lives in libbsm; read the pid field directly (val[5],
     * exactly what that macro expands to) so libkai needs no extra link. */
    if (pid) *pid = (int)tok.val[5];

    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&tok, sizeof tok);
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *vals[] = {data};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    int ok = 0;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code) == errSecSuccess) {
        SecRequirementRef req = NULL;
        SecRequirementCreateWithString(CFSTR("anchor apple generic"), kSecCSDefaultFlags, &req);
        OSStatus v = SecCodeCheckValidity(code, kSecCSDefaultFlags, req);
        if (req) CFRelease(req);
        if (v == errSecSuccess) {
            CFDictionaryRef info = NULL;
            if (SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSSigningInformation,
                                              &info) == errSecSuccess && info) {
                CFStringRef t = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
                if (t && team) CFStringGetCString(t, team, (CFIndex)tlen, kCFStringEncodingUTF8);
                CFStringRef s = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
                if (s && signid) CFStringGetCString(s, signid, (CFIndex)slen, kCFStringEncodingUTF8);
                CFRelease(info);
                ok = 1;
            }
        }
        CFRelease(code);
    }
    CFRelease(attrs);
    CFRelease(data);
    return ok;
}

int kai_pid_code_identity(int pid, char *out, size_t n) {
    if (n) out[0] = '\0';
    if (pid <= 0) return 0;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = {kSecGuestAttributePid};
    const void *vals[] = {num};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    int ok = 0;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code) == errSecSuccess) {
        SecRequirementRef req = NULL;
        SecRequirementCreateWithString(CFSTR("anchor apple generic"), kSecCSDefaultFlags, &req);
        if (SecCodeCheckValidity(code, kSecCSDefaultFlags, req) == errSecSuccess) {
            CFDictionaryRef info = NULL;
            if (SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSSigningInformation,
                                              &info) == errSecSuccess && info) {
                char sid[128] = "", team[32] = "";
                CFStringRef s = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
                CFStringRef t = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
                if (s) CFStringGetCString(s, sid, sizeof sid, kCFStringEncodingUTF8);
                if (t) CFStringGetCString(t, team, sizeof team, kCFStringEncodingUTF8);
                if (sid[0]) { snprintf(out, n, "%s (%s)", sid, team[0] ? team : "Apple"); ok = 1; }
                CFRelease(info);
            }
        }
        if (req) CFRelease(req);
        CFRelease(code);
    }
    CFRelease(attrs);
    CFRelease(num);
    return ok;
}

/* The executable path of a pid, "" if unavailable. Cheap (one syscall). */
void kai_pid_exe(int pid, char *out, size_t n) {
    if (n) out[0] = '\0';
    if (proc_pidpath(pid, out, (uint32_t)n) <= 0 && n) out[0] = '\0';
}

#else /* Linux, Windows: the platform layer reads the process */

int kai_proc_read(int pid, kai_proc *out) { return kai_plat_proc_read(pid, out); }
int kai_proc_read_fast(int pid, kai_proc *out) { return kai_proc_read(pid, out); }
int kai_pid_code_identity(int pid, char *out, size_t n) { (void)pid; if (n) out[0] = '\0'; return 0; }
void kai_pid_exe(int pid, char *out, size_t n) { kai_plat_pid_exe(pid, out, n); }
/* No XPC/SecCode off macOS; the control service is macOS-only. */
int kai_audit_token_identity(const void *tokbytes, size_t toklen, char *team, size_t tlen,
                             char *signid, size_t slen, int *pid) {
    (void)tokbytes; (void)toklen;
    if (team && tlen) team[0] = '\0';
    if (signid && slen) signid[0] = '\0';
    if (pid) *pid = -1;
    return 0;
}

#endif

int kai_agent_match(const kai_policy *p, const char *exe, const char *const *argv,
                    int argc, const char *team, char *name, size_t namelen) {
    if (name && namelen) name[0] = '\0';
    if (!p) return 0;
    for (int i = 0; i < p->nagents; i++) {
        const char *kind = p->agents[i].kind, *pat = p->agents[i].pattern;
        int hit = 0;
        if (strcmp(kind, "exe") == 0) {
            hit = exe && *exe && fnmatch(pat, exe, 0) == 0;
        } else if (strcmp(kind, "team") == 0) {
            hit = team && *team && strcmp(pat, team) == 0;
        } else if (strcmp(kind, "arg") == 0) {
            for (int a = 0; a < argc && !hit; a++)
                hit = argv[a] && fnmatch(pat, argv[a], 0) == 0;
        }
        if (hit) {
            if (name) kai_strlcpy(name, p->agents[i].name, namelen);
            return 1;
        }
    }
    return 0;
}

int kai_process_agent(const kai_policy *p, int pid, char *name, size_t namelen,
                      int *agent_pid) {
    if (name && namelen) name[0] = '\0';
    if (agent_pid) *agent_pid = 0;
    /* pid 1 is launchd/init: reaching it means no agent above us. */
    for (int depth = 0; pid > 1 && depth < 64; depth++) {
        kai_proc pr;
        if (kai_proc_read(pid, &pr) != 0) return 0;
        int hit = kai_agent_match(p, pr.exe, (const char *const *)pr.argv, pr.argc,
                                  pr.team, name, namelen);
        int parent = pr.ppid;
        kai_proc_free(&pr);
        if (hit) {
            if (agent_pid) *agent_pid = pid;
            return 1;
        }
        if (parent == pid) break;
        pid = parent;
    }
    return 0;
}

/* Phase A item 5: the ROOT of `agent`'s session that `pid` belongs to - the
 * topmost process in its ancestry (itself included) classified as that same
 * agent, which is the pid the session scan reports. The storage wall mints a
 * session keyed to it, so an agent started before the wall gets the same root
 * as the scan (and can be paused) rather than a session per child shell.
 * 0 if no such process. */
int kai_agent_root_pid(const kai_policy *p, int pid, const char *agent) {
    if (!p || !agent || !*agent) return 0;
    int root = 0;
    for (int depth = 0; pid > 1 && depth < 64; depth++) {
        kai_proc pr;
        if (kai_proc_read(pid, &pr) != 0) break;
        char name[64];
        if (kai_agent_match(p, pr.exe, (const char *const *)pr.argv, pr.argc, pr.team,
                            name, sizeof name) && strcmp(name, agent) == 0)
            root = pid;
        int parent = pr.ppid;
        kai_proc_free(&pr);
        if (parent == pid) break;
        pid = parent;
    }
    return root;
}

/* ---- storage-wall-free session discovery (S-redesign item 1) ---- */
#ifdef __APPLE__
/* Session scan (perf-tuned + classified). ONE fast pass over all processes (no
 * per-process code-signing lookup), building an in-memory table; agent roots,
 * nesting, host app and child counts come from in-memory ancestry walks. Each
 * agent process is classified (session / nested / background / orphan) so the
 * daemon/supervisor and nested agents are not counted as interactive sessions. */
static const struct { const char *mark, *name; } HOST_APPS[] = {
    {"/Terminal.app/", "Terminal"}, {"/iTerm.app/", "iTerm"},
    {"/Cursor.app/", "Cursor"}, {"/Visual Studio Code.app/", "VS Code"},
    {"/WezTerm.app/", "WezTerm"}, {"/Alacritty.app/", "Alacritty"},
    {"/kitty.app/", "kitty"}, {"/Warp.app/", "Warp"}, {"/Ghostty.app/", "Ghostty"},
};

typedef struct {
    int pid, parent, is_agent;
    char name[64], exe[1024], cmd[256], tty[24];
    long long started;
} scan_ent;

/* The process's controlling terminal name (e.g. "ttys001"), or "" if none. */
static void proc_tty(int pid, char *out, size_t n) {
    if (n) out[0] = '\0';
    struct kinfo_proc kp;
    size_t sz = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &sz, NULL, 0) == 0 && sz > 0) {
        dev_t t = kp.kp_eproc.e_tdev;
        if (t != NODEV && t != (dev_t)-1) {
            char *name = devname(t, S_IFCHR);
            if (name) snprintf(out, n, "%s", name);
        }
    }
}

int kai_sessions_scan(const kai_policy *p, kai_session **out, int *n) {
    *out = NULL; *n = 0;
    if (!p) return 0;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return 0;
    int maxp = bytes / (int)sizeof(pid_t) + 32;
    pid_t *pids = calloc((size_t)maxp, sizeof(pid_t));
    if (!pids) return 0;
    int got = proc_listpids(PROC_ALL_PIDS, 0, pids, maxp * (int)sizeof(pid_t));
    int np = got / (int)sizeof(pid_t);
    if (np > maxp) np = maxp;

    scan_ent *tab = calloc((size_t)(np > 0 ? np : 1), sizeof *tab);
    if (!tab) { free(pids); return 0; }
    int nt = 0;
    for (int i = 0; i < np; i++) {
        int pid = pids[i];
        if (pid <= 1) continue;
        kai_proc pr;
        if (kai_proc_read_fast(pid, &pr) != 0) continue;
        tab[nt].pid = pid;
        tab[nt].parent = pr.ppid;
        kai_strlcpy(tab[nt].exe, pr.exe, sizeof tab[nt].exe);
        /* join argv into a (truncated) command line for classification markers */
        size_t off = 0;
        for (int a = 0; a < pr.argc && off < sizeof tab[nt].cmd - 1; a++) {
            int w = snprintf(tab[nt].cmd + off, sizeof tab[nt].cmd - off, "%s%s",
                             a ? " " : "", pr.argv[a] ? pr.argv[a] : "");
            if (w < 0) break;
            off += (size_t)w;
        }
        tab[nt].is_agent = kai_agent_match(p, pr.exe, (const char *const *)pr.argv,
                                           pr.argc, "", tab[nt].name, sizeof tab[nt].name);
        kai_proc_free(&pr);
        nt++;
    }
    free(pids);

    /* Resolve each entry's parent to a table index (no syscalls after this). */
    for (int i = 0; i < nt; i++) {
        int ppid = tab[i].parent, idx = -1;
        for (int j = 0; j < nt; j++) if (tab[j].pid == ppid) { idx = j; break; }
        tab[i].parent = idx;
    }

    long long now = (long long)time(NULL);
    kai_session *arr = NULL; int count = 0, cap = 0;
    for (int i = 0; i < nt; i++) {
        if (!tab[i].is_agent) continue;
        /* Nested: ANY ancestor is the same agent -> folded into that session. */
        int nested = 0, parent_is_launchd = (tab[i].parent < 0);
        for (int a = tab[i].parent, depth = 0; a >= 0 && depth < 64; a = tab[a].parent, depth++) {
            if (tab[a].is_agent && strcmp(tab[a].name, tab[i].name) == 0) { nested = 1; break; }
        }
        if (nested) continue;   /* shown inside its parent session, not counted */

        char tty[24] = "";
        proc_tty(tab[i].pid, tty, sizeof tty);
        long long started = 0;
        struct proc_bsdinfo bi;
        if (proc_pidinfo(tab[i].pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == (int)sizeof bi)
            started = (long long)bi.pbi_start_tvsec;
        long long age = started > 0 ? now - started : 0;

        /* Item 2: an IDE agent (Cursor, Zed, …) is a HOST, not a background
         * service. Its sessions are its open workspaces — the distinct working
         * directories of its child processes — so one long-lived app process
         * becomes one session per window/workspace. */
        if (kai_agent_product_kind(tab[i].name) == KAI_AGENT_IDE) {
            /* Skip the IDE's helper processes (renderer/GPU/plugin host); the
             * main app process carries the workspaces. */
            if (strstr(tab[i].exe, "Helper") || strstr(tab[i].exe, "(GPU)") ||
                strstr(tab[i].exe, "(Renderer)") || strstr(tab[i].exe, "(Plugin)"))
                continue;
            const char *home = getenv("HOME");
            char ws[16][1024]; int nws = 0;
            for (int j = 0; j < nt && nws < 16; j++) {
                int isdesc = (j == i);
                for (int a = tab[j].parent, d = 0; !isdesc && a >= 0 && d < 64; a = tab[a].parent, d++)
                    if (a == i) isdesc = 1;
                if (!isdesc) continue;
                struct proc_vnodepathinfo v;
                if (proc_pidinfo(tab[j].pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof v) <= 0) continue;
                const char *cwd = v.pvi_cdir.vip_path;
                if (!cwd[0] || !strcmp(cwd, "/") || (home && !strcmp(cwd, home))) continue;
                int dup = 0;
                for (int k = 0; k < nws; k++) if (!strcmp(ws[k], cwd)) { dup = 1; break; }
                if (!dup) kai_strlcpy(ws[nws], cwd, sizeof ws[0]), nws++;
            }
            char hostname[64];
            kai_strlcpy(hostname, tab[i].name, sizeof hostname);
            if (hostname[0] >= 'a' && hostname[0] <= 'z') hostname[0] -= 32;  /* "cursor" -> "Cursor" */
            int emit_n = nws > 0 ? nws : 1;
            for (int w = 0; w < emit_n; w++) {
                kai_session s;
                memset(&s, 0, sizeof s);
                snprintf(s.id, sizeof s.id, "scan-%d-%d", tab[i].pid, w);
                kai_strlcpy(s.agent, tab[i].name, sizeof s.agent);
                s.root_pid = tab[i].pid;
                s.source = KAI_SESS_SCAN;
                s.kind = KAI_KIND_SESSION;      /* a host workspace is a session */
                s.started_utc = started;
                kai_strlcpy(s.host_app, hostname, sizeof s.host_app);
                kai_strlcpy(s.project, nws > 0 ? ws[w] : "(IDE host)", sizeof s.project);
                if (count == cap) {
                    int nc = cap ? cap * 2 : 8;
                    kai_session *na = realloc(arr, (size_t)nc * sizeof *na);
                    if (!na) break;
                    arr = na; cap = nc;
                }
                arr[count++] = s;
            }
            continue;
        }

        int kind = kai_classify_session(tab[i].cmd, tty[0] != '\0', parent_is_launchd, age, 0);

        kai_session s;
        memset(&s, 0, sizeof s);
        snprintf(s.id, sizeof s.id, "scan-%d", tab[i].pid);
        kai_strlcpy(s.agent, tab[i].name, sizeof s.agent);
        s.root_pid = tab[i].pid;
        s.source = KAI_SESS_SCAN;
        s.kind = kind;
        s.started_utc = started;
        kai_strlcpy(s.tty, tty, sizeof s.tty);
        struct proc_vnodepathinfo vp;
        if (proc_pidinfo(tab[i].pid, PROC_PIDVNODEPATHINFO, 0, &vp, sizeof vp) > 0)
            kai_strlcpy(s.project, vp.pvi_cdir.vip_path, sizeof s.project);
        for (int a = tab[i].parent, depth = 0; a >= 0 && depth < 40; a = tab[a].parent, depth++) {
            int found = 0;
            for (size_t k = 0; k < sizeof HOST_APPS / sizeof HOST_APPS[0]; k++)
                if (strstr(tab[a].exe, HOST_APPS[k].mark)) {
                    kai_strlcpy(s.host_app, HOST_APPS[k].name, sizeof s.host_app); found = 1; break;
                }
            if (found) break;
        }
        for (int j = 0; j < nt; j++) {
            if (j == i) continue;
            for (int a = tab[j].parent, depth = 0; a >= 0 && depth < 64; a = tab[a].parent, depth++)
                if (a == i) { s.child_count++; break; }
        }
        if (count == cap) {
            int nc = cap ? cap * 2 : 8;
            kai_session *na = realloc(arr, (size_t)nc * sizeof *na);
            if (!na) break;
            arr = na; cap = nc;
        }
        arr[count++] = s;
    }
    free(tab);
    *out = arr; *n = count;
    return count;
}

#else
/* The same scan from the platform layer's process list (Windows; Linux lists
 * nothing yet, so it finds no sessions, as before). One pass over all
 * processes, then ancestry walks in memory. There is no controlling terminal
 * on Windows: a process run from a terminal or a shell (Windows Terminal,
 * PowerShell, an editor's terminal) counts as interactive, and that program
 * is its host app. */
typedef struct {
    int pid, parent, is_agent;
    char name[64], exe[1024], cmd[256];
} scan_ent;

int kai_sessions_scan(const kai_policy *p, kai_session **out, int *n) {
    *out = NULL; *n = 0;
    if (!p) return 0;
    int *pids = NULL;
    int np = kai_plat_list_pids(&pids);
    if (np <= 0) { free(pids); return 0; }
    scan_ent *tab = calloc((size_t)np, sizeof *tab);
    if (!tab) { free(pids); return 0; }
    int nt = 0;
    for (int i = 0; i < np; i++) {
        kai_proc pr;
        if (pids[i] <= 4 || kai_proc_read_fast(pids[i], &pr) != 0) continue;
        scan_ent *t = &tab[nt];
        t->pid = pids[i];
        t->parent = pr.ppid;
        kai_strlcpy(t->exe, pr.exe, sizeof t->exe);
        size_t off = 0;
        for (int a = 0; a < pr.argc && off < sizeof t->cmd - 1; a++) {
            int w = snprintf(t->cmd + off, sizeof t->cmd - off, "%s%s", a ? " " : "", pr.argv[a] ? pr.argv[a] : "");
            if (w < 0) break;
            off += (size_t)w;
        }
        t->is_agent = kai_agent_match(p, pr.exe, (const char *const *)pr.argv, pr.argc, "", t->name, sizeof t->name);
        kai_proc_free(&pr);
        nt++;
    }
    free(pids);
    for (int i = 0; i < nt; i++) {
        int idx = -1;
        for (int j = 0; j < nt; j++) if (tab[j].pid == tab[i].parent && j != i) { idx = j; break; }
        tab[i].parent = idx;
    }
    long long now = (long long)time(NULL);
    kai_session *arr = NULL;
    int count = 0, cap = 0;
    for (int i = 0; i < nt; i++) {
        if (!tab[i].is_agent) continue;
        int nested = 0;
        for (int a = tab[i].parent, d = 0; a >= 0 && d < 64; a = tab[a].parent, d++)
            if (tab[a].is_agent && !strcmp(tab[a].name, tab[i].name)) { nested = 1; break; }
        if (nested) continue;   /* its helpers and child copies belong to the session above */
        char host[64] = "";   /* the terminal app above it, else the nearest shell */
        int host_rank = 0;
        for (int a = tab[i].parent, d = 0; a >= 0 && d < 40 && host_rank < 2; a = tab[a].parent, d++) {
            char h[64];
            int r = kai_plat_terminal_host(tab[a].exe, h, sizeof h);
            if (r > host_rank) { host_rank = r; kai_strlcpy(host, h, sizeof host); }
        }
        long long started = kai_plat_proc_started(tab[i].pid);
        long long age = started > 0 ? now - started : 0;
        int is_ide = kai_agent_product_kind(tab[i].name) == KAI_AGENT_IDE;
        kai_session s;
        memset(&s, 0, sizeof s);
        snprintf(s.id, sizeof s.id, "scan-%d", tab[i].pid);
        kai_strlcpy(s.agent, tab[i].name, sizeof s.agent);
        s.root_pid = tab[i].pid;
        s.source = KAI_SESS_SCAN;
        s.started_utc = started;
        s.kind = is_ide ? KAI_KIND_SESSION : kai_classify_session(tab[i].cmd, host[0] != '\0', tab[i].parent < 0, age, 0);
        if (is_ide) {
            kai_strlcpy(s.host_app, tab[i].name, sizeof s.host_app);
            if (s.host_app[0] >= 'a' && s.host_app[0] <= 'z') s.host_app[0] -= 32;   /* "cursor" -> "Cursor" */
        } else {
            kai_strlcpy(s.host_app, host, sizeof s.host_app);
        }
        kai_plat_proc_cwd(tab[i].pid, s.project, sizeof s.project);
        for (int j = 0; j < nt; j++)
            for (int a = tab[j].parent, d = 0; j != i && a >= 0 && d < 64; a = tab[a].parent, d++)
                if (a == i) { s.child_count++; break; }
        if (count == cap) {
            int nc = cap ? cap * 2 : 8;
            kai_session *na = realloc(arr, (size_t)nc * sizeof *na);
            if (!na) break;
            arr = na;
            cap = nc;
        }
        arr[count++] = s;
    }
    free(tab);
    *out = arr;
    *n = count;
    return count;
}
#endif
