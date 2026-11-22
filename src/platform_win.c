/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Platform layer, Windows 10/11 (MSVC). See platform.h and
 * docs/windows/PORTING.md. Also implements the POSIX shims declared in
 * compat/win/. Every path crossing into Win32 goes through UTF-16 (W APIs). */
#include "platform.h"
#include "internal.h"

#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shellapi.h>
#include <tlhelp32.h>

#include <ctype.h>
#include <dirent.h>
#include <fnmatch.h>
#include <pthread.h>
#include <pwd.h>
#include <readpassphrase.h>
#include <regex.h>
#include <stdarg.h>
#include <sys/file.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

/* The shims are macros for the engine; here we need the CRT originals. */
#undef open
#undef stat
#undef fstat
#undef lstat
#undef mkdir
#undef rename
#undef unlink
#undef chmod
#undef realpath
#undef kill
#undef sleep
#undef usleep

/* ---------------------------------------------------------------- UTF-8 */

static wchar_t *wide(const char *s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = malloc((size_t)n * sizeof *w);
    if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

static char *narrow(const wchar_t *w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = malloc((size_t)n);
    if (s) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

static void slashes(char *s) {
    for (; s && *s; s++) if (*s == '\\') *s = '/';
}

static int is_drive(const char *p);

static int set_errno_from_win(void) {
    DWORD e = GetLastError();
    switch (e) {
    case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_INVALID_NAME: errno = ENOENT; break;
    case ERROR_ACCESS_DENIED: case ERROR_SHARING_VIOLATION: case ERROR_LOCK_VIOLATION: errno = EACCES; break;
    case ERROR_ALREADY_EXISTS: case ERROR_FILE_EXISTS: errno = EEXIST; break;
    case ERROR_DIR_NOT_EMPTY: errno = ENOTEMPTY; break;
    default: errno = EIO; break;
    }
    return -1;
}

/* ------------------------------------------------------------ init/home */

void kai_plat_init(void) {
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    /* Files kai opens or creates default to binary, like POSIX. */
    _set_fmode(_O_BINARY);
}

int kai_plat_is_windows(void) { return 1; }

static char *env_utf8(const wchar_t *name) {
    DWORD n = GetEnvironmentVariableW(name, NULL, 0);
    if (!n) return NULL;
    wchar_t *w = malloc((size_t)n * sizeof *w);
    if (!w) return NULL;
    GetEnvironmentVariableW(name, w, n);
    char *s = narrow(w);
    free(w);
    return s;
}

const char *kai_plat_home(void) {
    static char buf[PATH_MAX];
    /* %USERPROFILE%, as Windows itself resolves "~" for Claude Code, Codex and
     * Cursor. Tests point it at a throwaway folder (as they set HOME on POSIX). */
    char *h = env_utf8(L"USERPROFILE");
    if (!h || !*h) {
        free(h);
        char *d = env_utf8(L"HOMEDRIVE"), *p = env_utf8(L"HOMEPATH");
        if (d && p) {
            h = malloc(strlen(d) + strlen(p) + 1);
            if (h) { strcpy(h, d); strcat(h, p); }
        }
        free(d); free(p);
    }
    if (!h) { kai_strlcpy(buf, "C:/", sizeof buf); return buf; }
    slashes(h);
    if (h[0] && h[1] == ':') h[0] = (char)toupper((unsigned char)h[0]);
    size_t l = strlen(h);
    while (l > 3 && h[l - 1] == '/') h[--l] = '\0';
    kai_strlcpy(buf, h, sizeof buf);
    free(h);
    return buf;
}

/* Windows' own secret stores, on top of the built-in list (which already has
 * ~/.ssh, ~/.aws, ~/.kube, ~/.docker/config.json, ~/.npmrc, .env, keys...). */
const char *kai_plat_default_policy_extra(void) {
    return "protect ~/.azure\n"
           "protect ~/.git-credentials\n"
           "protect %APPDATA%/gcloud\n"
           "protect %APPDATA%/npm/etc/npmrc\n"
           "protect %APPDATA%/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt\n"
           "protect %APPDATA%/Microsoft/Credentials\n"
           "protect %LOCALAPPDATA%/Microsoft/Credentials\n"
           "protect %APPDATA%/Microsoft/Protect\n"
           "protect \"%LOCALAPPDATA%/Google/Chrome/User Data\"\n"
           "protect \"%LOCALAPPDATA%/Microsoft/Edge/User Data\"\n"
           "protect \"%LOCALAPPDATA%/BraveSoftware/Brave-Browser/User Data\"\n"
           "protect %APPDATA%/Mozilla/Firefox/Profiles\n";
}

void kai_plat_slashes(char *s) { slashes(s); }

const char *kai_plat_program_dir(void) {
    static char buf[PATH_MAX];
    if (buf[0]) return buf;
    char *l = env_utf8(L"LOCALAPPDATA");
    if (!l || !*l) { free(l); return NULL; }
    slashes(l);
    if (is_drive(l)) l[0] = (char)toupper((unsigned char)l[0]);
    snprintf(buf, sizeof buf, "%s/Programs/Kai", l);
    free(l);
    return buf;
}

/* ---------------------------------------------------------------- paths */

static int is_drive(const char *p) {
    return isalpha((unsigned char)p[0]) && p[1] == ':';
}

size_t kai_plat_root_len(const char *p) {
    if (!p) return 0;
    if (is_drive(p) && p[2] == '/') return 3;
    if (p[0] == '/' && p[1] == '/' && p[2] && p[2] != '/') {   /* //server/share/ */
        const char *s = strchr(p + 2, '/');
        if (!s) return strlen(p);
        const char *e = strchr(s + 1, '/');
        return e ? (size_t)(e - p) + 1 : strlen(p);
    }
    return 0;
}

int kai_plat_path_is_abs(const char *p) { return kai_plat_root_len(p) > 0; }

/* %NAME%, $env:NAME, ${env:NAME}: expanded with the process environment. */
char *kai_plat_expand_env(const char *s) {
    if (!s || (!strchr(s, '%') && !strstr(s, "env:") && !strstr(s, "ENV:") && !strstr(s, "Env:"))) return NULL;
    sb_t b;
    sb_init(&b);
    int changed = 0;
    for (const char *c = s; *c;) {
        const char *name = NULL;
        size_t nl = 0, skip = 0;
        if (*c == '%') {
            const char *e = strchr(c + 1, '%');
            if (e && e > c + 1) {
                int ok = 1;
                for (const char *k = c + 1; k < e; k++)
                    if (!(isalnum((unsigned char)*k) || strchr("_()-.", *k))) { ok = 0; break; }
                if (ok) { name = c + 1; nl = (size_t)(e - c - 1); skip = nl + 2; }
            }
        } else if (*c == '$' && !_strnicmp(c + 1, "env:", 4)) {
            name = c + 5;
            while (isalnum((unsigned char)name[nl]) || name[nl] == '_') nl++;
            skip = 5 + nl;
        } else if (*c == '$' && c[1] == '{' && !_strnicmp(c + 2, "env:", 4)) {
            const char *e = strchr(c + 6, '}');
            if (e) { name = c + 6; nl = (size_t)(e - name); skip = nl + 7; }
        }
        if (name && nl && nl < 256) {
            char nm[256];
            memcpy(nm, name, nl);
            nm[nl] = '\0';
            wchar_t *wn = wide(nm);
            char *v = NULL;
            if (!_stricmp(nm, "HOME") || !_stricmp(nm, "USERPROFILE")) v = _strdup(kai_plat_home());
            else if (wn) v = env_utf8(wn);
            free(wn);
            if (v) { sb_adds(&b, v); free(v); c += skip; changed = 1; continue; }
        }
        sb_add(&b, c, 1);
        c++;
    }
    if (!changed) { sb_free(&b); return NULL; }
    return sb_take(&b);
}

static char *cwd_now(void) {
    DWORD n = GetCurrentDirectoryW(0, NULL);
    wchar_t *w = malloc(((size_t)n + 1) * sizeof *w);
    if (!w) return NULL;
    GetCurrentDirectoryW(n + 1, w);
    char *s = narrow(w);
    free(w);
    return s;
}

/* "\\?\C:\x" -> "C:/x", "\\?\UNC\s\sh" -> "//s/sh", "/c/x" (Git Bash) ->
 * "C:/x", "/cygdrive/c/x" -> "C:/x". In place on a '/'-converted copy. */
/* "//localhost/C$/x" is "C:/x": an administrative share of this machine
 * (localhost, 127.0.0.1, ::1, ".", or the computer's own name). */
static void local_admin_share(char *p) {
    if (p[0] != '/' || p[1] != '/') return;
    const char *host = p + 2, *slash = strchr(host, '/');
    if (!slash) return;
    size_t hl = (size_t)(slash - host);
    const char *share = slash + 1;
    if (!isalpha((unsigned char)share[0]) || share[1] != '$' || (share[2] && share[2] != '/')) return;
    char me[256] = "";
    wchar_t wn[256];
    DWORD n = 256;
    if (GetComputerNameExW(ComputerNamePhysicalNetBIOS, wn, &n)) {
        char *s = narrow(wn);
        if (s) { kai_strlcpy(me, s, sizeof me); free(s); }
    }
    static const char *const local[] = {"localhost", "127.0.0.1", "::1", "[::1]", "0--1.ipv6-literal.net", "."};
    int hit = me[0] && strlen(me) == hl && !_strnicmp(host, me, hl);
    for (size_t i = 0; !hit && i < sizeof local / sizeof local[0]; i++)
        hit = strlen(local[i]) == hl && !_strnicmp(host, local[i], hl);
    if (!hit) return;
    char d = (char)toupper((unsigned char)share[0]);
    const char *rest = share + 2;   /* "" or "/..." */
    size_t rl = strlen(rest);
    p[0] = d; p[1] = ':';
    if (rl) memmove(p + 2, rest, rl + 1);
    else { p[2] = '/'; p[3] = '\0'; }
}

static void drop_prefixes(char *p) {
    size_t l = strlen(p);
    if (!strncmp(p, "//?/UNC/", 8) || !strncmp(p, "//./UNC/", 8) || !_strnicmp(p, "//?/unc/", 8)) {
        memmove(p + 2, p + 8, l - 8 + 1);
        local_admin_share(p);
        return;
    }
    local_admin_share(p);
    if (is_drive(p)) return;
    if ((!strncmp(p, "//?/", 4) || !strncmp(p, "//./", 4) || !strncmp(p, "/??/", 4)) && is_drive(p + 4)) {
        memmove(p, p + 4, l - 4 + 1);
        return;
    }
    if (!_strnicmp(p, "/cygdrive/", 10) && isalpha((unsigned char)p[10]) && (p[11] == '/' || !p[11])) {
        char d = p[10];
        memmove(p + 2, p + 11, l - 11 + 1);
        p[0] = d; p[1] = ':';
        if (!p[2]) { p[2] = '/'; p[3] = '\0'; }
        return;
    }
    /* Git Bash / MSYS drive mounts: /c or /c/... is C:\. */
    if (p[0] == '/' && isalpha((unsigned char)p[1]) && (p[2] == '/' || !p[2])) {
        char d = p[1];
        p[0] = d; p[1] = ':';
        if (!p[2]) { p[2] = '/'; p[3] = '\0'; }
    }
}

static char *expand_all(const char *path) {
    char *e = kai_plat_expand_env(path);
    const char *src = e ? e : path;
    sb_t b;
    sb_init(&b);
    if (src[0] == '~' && (src[1] == '/' || src[1] == '\\' || !src[1])) {
        sb_adds(&b, kai_plat_home());
        src++;
    } else if (!strncmp(src, "${HOME}", 7)) {
        sb_adds(&b, kai_plat_home());
        src += 7;
    } else if (!strncmp(src, "$HOME", 5) && (src[5] == '/' || src[5] == '\\' || !src[5])) {
        sb_adds(&b, kai_plat_home());
        src += 5;
    }
    sb_adds(&b, src);
    free(e);
    char *r = sb_take(&b);
    slashes(r);
    drop_prefixes(r);
    return r;
}

char *kai_plat_absolute(const char *path, const char *cwd) {
    char *p = expand_all(path ? path : "");
    if (!p) return NULL;
    if (is_drive(p)) p[0] = (char)toupper((unsigned char)p[0]);
    if (kai_plat_path_is_abs(p)) return p;
    /* the folder relative paths start from, in the same form */
    char *c = (cwd && *cwd) ? expand_all(cwd) : cwd_now();
    if (c) {
        slashes(c);
        if (is_drive(c)) c[0] = (char)toupper((unsigned char)c[0]);
        if (!kai_plat_path_is_abs(c)) {   /* "C:" alone: the drive's root */
            if (is_drive(c) && !c[2]) { char *t = malloc(4); if (t) { t[0] = c[0]; t[1] = ':'; t[2] = '/'; t[3] = 0; } free(c); c = t; }
            else { free(c); c = cwd_now(); if (c) slashes(c); }
        }
    }
    if (!c) c = _strdup("C:/");
    sb_t b;
    sb_init(&b);
    if (p[0] == '/' && p[1] != '/') {               /* rooted: \foo on the cwd's drive */
        size_t rl = kai_plat_root_len(c);
        if (is_drive(c)) sb_add(&b, c, 2);
        else if (rl) sb_add(&b, c, rl - 1);         /* //server/share */
        sb_adds(&b, p);
    } else if (is_drive(p)) {                       /* drive-relative: C:foo */
        if (toupper((unsigned char)c[0]) == p[0] && is_drive(c)) {
            sb_adds(&b, c);
            sb_adds(&b, "/");
        } else {
            sb_add(&b, p, 2);
            sb_adds(&b, "/");
        }
        sb_adds(&b, p + 2);
    } else {
        sb_adds(&b, c);
        sb_adds(&b, "/");
        sb_adds(&b, p);
    }
    free(c);
    free(p);
    return sb_take(&b);
}

/* What Windows opens for this name: ".env::$DATA" and "id_ed25519:stream"
 * are the base file; trailing dots and spaces are ignored. */
void kai_plat_fix_component(char *comp) {
    if (!comp || !strcmp(comp, ".") || !strcmp(comp, "..")) return;
    char *colon = strchr(comp, ':');
    if (colon) *colon = '\0';
    size_t l = strlen(comp);
    while (l && (comp[l - 1] == '.' || comp[l - 1] == ' ')) comp[--l] = '\0';
}

/* ------------------------------------------------------------- realpath */

/* GetFinalPathNameByHandleW resolves symlinks, junctions, mount points and
 * 8.3 short names, and gives the on-disk letter case. */
char *kai_win_realpath(const char *path, char *resolved) {
    if (!path || !*path) { errno = ENOENT; return NULL; }
    char *abs = kai_plat_absolute(path, NULL);
    if (!abs) { errno = ENOMEM; return NULL; }
    if (is_drive(abs) && !abs[2]) { abs[2] = '/'; abs[3] = '\0'; }
    wchar_t *w = wide(abs);
    free(abs);
    if (!w) { errno = ENOMEM; return NULL; }
    HANDLE h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) { set_errno_from_win(); return NULL; }
    wchar_t buf[32768];
    DWORD n = GetFinalPathNameByHandleW(h, buf, (DWORD)(sizeof buf / sizeof buf[0]), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    if (!n || n >= sizeof buf / sizeof buf[0]) { set_errno_from_win(); return NULL; }
    char *s = narrow(buf);
    if (!s) { errno = ENOMEM; return NULL; }
    slashes(s);
    drop_prefixes(s);
    if (is_drive(s)) s[0] = (char)toupper((unsigned char)s[0]);
    size_t l = strlen(s);
    while (l > 3 && s[l - 1] == '/') s[--l] = '\0';
    if (l >= PATH_MAX) { free(s); errno = ENAMETOOLONG; return NULL; }
    if (resolved) { memcpy(resolved, s, l + 1); free(s); return resolved; }
    return s;
}

int kai_plat_exe_path(char *buf, size_t n) {
    wchar_t w[32768];
    DWORD l = GetModuleFileNameW(NULL, w, (DWORD)(sizeof w / sizeof w[0]));
    if (!l || l >= sizeof w / sizeof w[0]) return -1;
    char *s = narrow(w);
    if (!s) return -1;
    slashes(s);
    if (is_drive(s)) s[0] = (char)toupper((unsigned char)s[0]);
    int ok = strlen(s) < n;
    if (ok) kai_strlcpy(buf, s, n);
    free(s);
    return ok ? 0 : -1;
}

/* Creation time from the file system (100 ns units since 1601). */
void kai_plat_file_birth(const char *path, const struct _stat64 *st, long long *sec, long long *nsec) {
    WIN32_FILE_ATTRIBUTE_DATA fa;
    wchar_t *w = wide(path);
    if (w && GetFileAttributesExW(w, GetFileExInfoStandard, &fa)) {
        unsigned long long t = ((unsigned long long)fa.ftCreationTime.dwHighDateTime << 32) | fa.ftCreationTime.dwLowDateTime;
        t -= 116444736000000000ULL;   /* 1601 -> 1970 */
        *sec = (long long)(t / 10000000ULL);
        *nsec = (long long)(t % 10000000ULL) * 100;
    } else {
        *sec = (long long)st->st_ctime;   /* the CRT's st_ctime is the creation time */
        *nsec = 0;
    }
    free(w);
}

long long kai_plat_mtime_ns(const struct _stat64 *st) { return (long long)st->st_mtime * 1000000000LL; }

/* ------------------------------------------------------------- run/pids */

int kai_plat_run(const char *cmdline, int shell, const char *input, size_t inlen, char *out, size_t outlen,
                 size_t *outgot, int timeout_ms) {
    if (outlen) out[0] = '\0';
    if (outgot) *outgot = 0;
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    HANDLE in_r, in_w, out_r, out_w;
    if (!CreatePipe(&in_r, &in_w, &sa, 1 << 16)) return -1;
    if (!CreatePipe(&out_r, &out_w, &sa, 1 << 16)) { CloseHandle(in_r); CloseHandle(in_w); return -1; }
    SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = nul;
    PROCESS_INFORMATION pi;
    char *line = NULL;
    if (shell) {   /* as Codex and Cursor run a hook command: PowerShell */
        char *av[] = {"powershell.exe", "-NoProfile", "-NonInteractive", "-Command", (char *)cmdline, NULL};
        line = kai_plat_quote_argv(av);
    }
    wchar_t *wc = wide(line ? line : cmdline);
    free(line);
    BOOL ok = wc && CreateProcessW(NULL, wc, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    free(wc);
    CloseHandle(in_r);
    CloseHandle(out_w);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!ok) { CloseHandle(in_w); CloseHandle(out_r); return -1; }
    DWORD wrote = 0;
    if (inlen) WriteFile(in_w, input, (DWORD)inlen, &wrote, NULL);
    CloseHandle(in_w);
    size_t got = 0;
    long long t0 = kai_plat_now_ms();
    for (;;) {
        long long left = timeout_ms - (kai_plat_now_ms() - t0);
        if (left <= 0) break;
        DWORD avail = 0;
        if (!PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL)) break;   /* closed: child done */
        if (!avail) {
            if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
                if (!PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL) || !avail) break;
            } else { Sleep(5); continue; }
        }
        char buf[1024];
        DWORD n = 0;
        if (!ReadFile(out_r, buf, avail < sizeof buf ? avail : (DWORD)sizeof buf, &n, NULL) || !n) break;
        if (got + 1 < outlen) {
            size_t take = (size_t)n < outlen - 1 - got ? (size_t)n : outlen - 1 - got;
            memcpy(out + got, buf, take);
            got += take;
            out[got] = '\0';
        }
    }
    CloseHandle(out_r);
    if (outgot) *outgot = got;
    int rc = -1;
    if (WaitForSingleObject(pi.hProcess, 500) == WAIT_OBJECT_0) {
        DWORD code = 0;
        if (GetExitCodeProcess(pi.hProcess, &code)) rc = (int)(code & 0xff);
    } else {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 1000);
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return rc;
}

/* One argument quoted for CommandLineToArgvW / the MSVC CRT. */
static void quote_arg(sb_t *b, const char *a) {
    if (*a && !strpbrk(a, " \t\n\v\"")) { sb_adds(b, a); return; }
    sb_adds(b, "\"");
    for (const char *c = a;; c++) {
        size_t bs = 0;
        while (*c == '\\') { c++; bs++; }
        if (!*c) { for (size_t i = 0; i < bs * 2; i++) sb_adds(b, "\\"); break; }
        if (*c == '"') { for (size_t i = 0; i < bs * 2 + 1; i++) sb_adds(b, "\\"); sb_add(b, c, 1); }
        else { for (size_t i = 0; i < bs; i++) sb_adds(b, "\\"); sb_add(b, c, 1); }
    }
    sb_adds(b, "\"");
}

char *kai_plat_quote_argv(char *const argv[]) {
    sb_t b;
    sb_init(&b);
    for (int i = 0; argv[i]; i++) {
        if (i) sb_adds(&b, " ");
        quote_arg(&b, argv[i]);
    }
    return sb_take(&b);
}

int kai_plat_run_argv(char *const argv[], const char *cwd, int timeout_s, char *out, size_t n) {
    if (n) out[0] = '\0';
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    HANDLE r, w;
    if (!CreatePipe(&r, &w, &sa, 1 << 16)) return -1;
    SetHandleInformation(r, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ, &sa, OPEN_EXISTING, 0, NULL);
    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = w;
    si.hStdError = w;
    char *cl = kai_plat_quote_argv(argv);
    wchar_t *wc = wide(cl), *wd = cwd ? wide(cwd) : NULL;
    free(cl);
    PROCESS_INFORMATION pi;
    BOOL ok = wc && CreateProcessW(NULL, wc, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, wd, &si, &pi);
    free(wc); free(wd);
    CloseHandle(w);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!ok) { CloseHandle(r); return -1; }
    size_t got = 0;
    long long end = kai_plat_now_ms() + (long long)timeout_s * 1000;
    int timed_out = 0;
    for (;;) {
        if (kai_plat_now_ms() >= end) { timed_out = 1; break; }
        DWORD avail = 0;
        if (!PeekNamedPipe(r, NULL, 0, NULL, &avail, NULL)) break;
        if (!avail) { Sleep(10); continue; }
        char buf[4096];
        DWORD k = 0;
        if (!ReadFile(r, buf, avail < sizeof buf ? avail : (DWORD)sizeof buf, &k, NULL) || !k) break;
        if (n && got < n - 1) {
            size_t c = (size_t)k < n - 1 - got ? (size_t)k : n - 1 - got;
            memcpy(out + got, buf, c); got += c; out[got] = '\0';
        }
    }
    CloseHandle(r);
    int rc = -1;
    if (timed_out || WaitForSingleObject(pi.hProcess, 2000) != WAIT_OBJECT_0) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 1000);
    } else {
        DWORD code = 0;
        if (GetExitCodeProcess(pi.hProcess, &code)) rc = (int)(code & 0xff);
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return rc;
}

int kai_plat_short_path(const char *path, char *out, size_t n) {
    wchar_t *w = wide(path);
    if (!w) return -1;
    wchar_t buf[32768];
    DWORD l = GetShortPathNameW(w, buf, (DWORD)(sizeof buf / sizeof buf[0]));
    free(w);
    if (!l || l >= sizeof buf / sizeof buf[0]) return -1;
    char *s = narrow(buf);
    if (!s) return -1;
    slashes(s);
    int ok = strlen(s) < n;
    if (ok) kai_strlcpy(out, s, n);
    free(s);
    return ok ? 0 : -1;
}

int kai_plat_pid_alive(int pid) {
    if (pid <= 0) return 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!h) return GetLastError() == ERROR_ACCESS_DENIED;
    DWORD code = 0;
    int alive = GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
    CloseHandle(h);
    return alive;
}

long long kai_plat_now_ms(void) { return (long long)GetTickCount64(); }

int kai_plat_open_url(const char *url) {
    (void)url;
    return -1;   /* no Kai app on Windows yet */
}

/* ------------------------------------------------------------- processes */

void kai_plat_pid_exe(int pid, char *out, size_t n) {
    if (n) out[0] = 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!h) return;
    wchar_t w[32768];
    DWORD l = (DWORD)(sizeof w / sizeof w[0]);
    if (QueryFullProcessImageNameW(h, 0, w, &l)) {
        char *s = narrow(w);
        if (s) {
            slashes(s);
            kai_strlcpy(out, s, n);
            free(s);
        }
    }
    CloseHandle(h);
}

/* The command line of another process: ProcessCommandLineInformation (60),
 * Windows 8.1 and later, needs only PROCESS_QUERY_LIMITED_INFORMATION. */
typedef LONG(NTAPI *nt_query_fn)(HANDLE, int, PVOID, ULONG, PULONG);
typedef struct { USHORT Length, MaximumLength; PWSTR Buffer; } kai_ustr;

static wchar_t *process_cmdline(HANDLE h) {
    static nt_query_fn q;
    if (!q) {
        HMODULE nt = GetModuleHandleW(L"ntdll.dll");
        if (nt) q = (nt_query_fn)(void (*)(void))GetProcAddress(nt, "NtQueryInformationProcess");
        if (!q) return NULL;
    }
    ULONG need = 0;
    q(h, 60, NULL, 0, &need);
    if (!need || need > (1u << 20)) return NULL;
    BYTE *buf = malloc(need);
    if (!buf) return NULL;
    if (q(h, 60, buf, need, &need) < 0) { free(buf); return NULL; }
    kai_ustr *u = (kai_ustr *)buf;
    size_t chars = u->Length / sizeof(wchar_t);
    wchar_t *r = malloc((chars + 1) * sizeof *r);
    if (r) { memcpy(r, u->Buffer, chars * sizeof *r); r[chars] = 0; }
    free(buf);
    return r;
}

static void push_arg(kai_proc *pr, const char *s) {
    char **nv = realloc(pr->argv, (size_t)(pr->argc + 1) * sizeof *nv);
    if (!nv) return;
    pr->argv = nv;
    char *a = _strdup(s);
    if (a) pr->argv[pr->argc++] = a;
}

int kai_plat_proc_read(int pid, kai_proc *out) {
    memset(out, 0, sizeof *out);
    out->pid = pid;
    int found = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
            if ((int)pe.th32ProcessID == pid) { out->ppid = (int)pe.th32ParentProcessID; found = 1; break; }
        CloseHandle(snap);
    }
    if (!found) return -1;
    kai_plat_pid_exe(pid, out->exe, sizeof out->exe);
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (h) {
        wchar_t *cl = process_cmdline(h);
        CloseHandle(h);
        if (cl) {
            int argc = 0;
            LPWSTR *wv = CommandLineToArgvW(cl, &argc);
            for (int i = 0; wv && i < argc; i++) {
                char *a = narrow(wv[i]);
                if (a) { push_arg(out, a); free(a); }
            }
            if (wv) LocalFree(wv);
            free(cl);
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ ACL */

/* Rights that let someone change or replace the file. */
#define KAI_WRITE_RIGHTS (FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES | \
                          DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL)

static int sid_is_trusted(PSID sid, PSID me) {
    if (me && EqualSid(sid, me)) return 1;
    static const WELL_KNOWN_SID_TYPE ok[] = {WinLocalSystemSid, WinBuiltinAdministratorsSid,
                                             WinCreatorOwnerSid, WinLocalServiceSid, WinNetworkServiceSid};
    for (size_t i = 0; i < sizeof ok / sizeof ok[0]; i++)
        if (IsWellKnownSid(sid, ok[i])) return 1;
    return 0;
}

static PSID current_user_sid(BYTE *buf, DWORD n) {
    HANDLE tok;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return NULL;
    DWORD got = 0;
    BOOL ok = GetTokenInformation(tok, TokenUser, buf, n, &got);
    CloseHandle(tok);
    return ok ? ((TOKEN_USER *)buf)->User.Sid : NULL;
}

int kai_plat_others_can_write(const char *path, char *who, size_t n) {
    if (who && n) who[0] = '\0';
    wchar_t *w = wide(path);
    if (!w) return -1;
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR sd = NULL;
    DWORD r = GetNamedSecurityInfoW(w, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, &dacl, NULL, &sd);
    free(w);
    if (r != ERROR_SUCCESS) return -1;
    int res = 0;
    if (!dacl) {
        if (who) kai_strlcpy(who, "everyone (no access list)", n);
        res = 1;
    } else {
        BYTE ubuf[256];
        PSID me = current_user_sid(ubuf, sizeof ubuf);
        for (DWORD i = 0; i < dacl->AceCount && !res; i++) {
            ACE_HEADER *ace;
            if (!GetAce(dacl, i, (void **)&ace)) continue;
            if (ace->AceType != ACCESS_ALLOWED_ACE_TYPE) continue;
            if (ace->AceFlags & INHERIT_ONLY_ACE) continue;
            ACCESS_ALLOWED_ACE *a = (ACCESS_ALLOWED_ACE *)ace;
            if (!(a->Mask & KAI_WRITE_RIGHTS)) continue;
            PSID sid = (PSID)&a->SidStart;
            if (sid_is_trusted(sid, me)) continue;
            res = 1;
            if (who) {
                wchar_t name[256], dom[256];
                DWORD nl = 256, dl = 256;
                SID_NAME_USE use;
                if (LookupAccountSidW(NULL, sid, name, &nl, dom, &dl, &use)) {
                    char *s = narrow(name);
                    kai_strlcpy(who, s ? s : "another account", n);
                    free(s);
                } else {
                    LPWSTR str = NULL;
                    if (ConvertSidToStringSidW(sid, &str)) {
                        char *s = narrow(str);
                        kai_strlcpy(who, s ? s : "another account", n);
                        free(s);
                        LocalFree(str);
                    } else kai_strlcpy(who, "another account", n);
                }
            }
        }
    }
    LocalFree(sd);
    return res;
}

/* --------------------------------------------------------- POSIX: files */

int kai_win_open(const char *path, int flags, ...) {
    int mode = 0;
    if (flags & _O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    wchar_t *w = wide(path);
    if (!w) { errno = ENOENT; return -1; }
    int pm = _S_IREAD | ((mode & 0200) || !(flags & _O_CREAT) ? _S_IWRITE : 0);
    int fd = -1;
    _wsopen_s(&fd, w, flags | _O_BINARY | _O_NOINHERIT, _SH_DENYNO, pm);
    free(w);
    return fd;
}

int kai_win_lstat(const char *path, struct _stat64 *st) {
    wchar_t *w = wide(path);
    if (!w) { errno = ENOENT; return -1; }
    int r = _wstat64(w, st);
    free(w);
    return r;
}

int kai_win_mkdir(const char *path) {
    wchar_t *w = wide(path);
    if (!w) { errno = ENOENT; return -1; }
    int r = CreateDirectoryW(w, NULL) ? 0 : set_errno_from_win();
    free(w);
    return r;
}

int kai_win_rename(const char *from, const char *to) {
    wchar_t *a = wide(from), *b = wide(to);
    int r = (a && b && MoveFileExW(a, b, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) ? 0 : set_errno_from_win();
    free(a); free(b);
    return r;
}

int kai_win_unlink(const char *path) {
    wchar_t *w = wide(path);
    if (!w) { errno = ENOENT; return -1; }
    DWORD at = GetFileAttributesW(w);
    if (at != INVALID_FILE_ATTRIBUTES && (at & FILE_ATTRIBUTE_DIRECTORY) && !(at & FILE_ATTRIBUTE_REPARSE_POINT)) {
        free(w);
        errno = EISDIR;
        return -1;
    }
    if (at != INVALID_FILE_ATTRIBUTES && (at & FILE_ATTRIBUTE_READONLY))
        SetFileAttributesW(w, at & ~(DWORD)FILE_ATTRIBUTE_READONLY);
    int r;
    if (at != INVALID_FILE_ATTRIBUTES && (at & FILE_ATTRIBUTE_DIRECTORY)) r = RemoveDirectoryW(w) ? 0 : set_errno_from_win();
    else r = DeleteFileW(w) ? 0 : set_errno_from_win();
    free(w);
    return r;
}

int kai_win_chmod(const char *path, int mode) {
    wchar_t *w = wide(path);
    if (!w) { errno = ENOENT; return -1; }
    DWORD at = GetFileAttributesW(w);
    int r = -1;
    if (at == INVALID_FILE_ATTRIBUTES) set_errno_from_win();
    else {
        DWORD na = (mode & 0200) ? (at & ~(DWORD)FILE_ATTRIBUTE_READONLY) : (at | FILE_ATTRIBUTE_READONLY);
        if (at & FILE_ATTRIBUTE_DIRECTORY) na = at;   /* read-only means nothing on folders */
        r = (na == at || SetFileAttributesW(w, na)) ? 0 : set_errno_from_win();
    }
    free(w);
    return r;
}

int kai_win_futimes(int fd, const void *tv) {
    (void)tv;
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    if (h == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    return SetFileTime(h, NULL, &ft, &ft) ? 0 : set_errno_from_win();
}

int kai_win_symlink(const char *target, const char *path) {
    wchar_t *t = wide(target), *p = wide(path);
    if (!t || !p) { free(t); free(p); errno = ENOMEM; return -1; }
    for (wchar_t *c = t; *c; c++) if (*c == L'/') *c = L'\\';
    DWORD at = GetFileAttributesW(t);
    DWORD fl = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    if (at != INVALID_FILE_ATTRIBUTES && (at & FILE_ATTRIBUTE_DIRECTORY)) fl |= SYMBOLIC_LINK_FLAG_DIRECTORY;
    int r = CreateSymbolicLinkW(p, t, fl) ? 0 : set_errno_from_win();
    free(t); free(p);
    return r;
}

ssize_t kai_win_readlink(const char *path, char *buf, size_t n) {
    (void)path; (void)buf; (void)n;
    errno = EINVAL;
    return -1;
}

uint32_t kai_win_random(void) {
    uint32_t v = 0;
    BCryptGenRandom(NULL, (PUCHAR)&v, sizeof v, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    return v;
}

char *kai_win_mkdtemp(char *tmpl) {
    size_t l = strlen(tmpl);
    if (l < 6 || strcmp(tmpl + l - 6, "XXXXXX")) { errno = EINVAL; return NULL; }
    static const char cs[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (int tries = 0; tries < 100; tries++) {
        for (int i = 0; i < 6; i++) tmpl[l - 6 + i] = cs[kai_win_random() % (sizeof cs - 1)];
        if (kai_win_mkdir(tmpl) == 0) return tmpl;
        if (errno != EEXIST) return NULL;
    }
    return NULL;
}

int kai_win_mkstemp(char *tmpl) {
    size_t l = strlen(tmpl);
    if (l < 6 || strcmp(tmpl + l - 6, "XXXXXX")) { errno = EINVAL; return -1; }
    static const char cs[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (int tries = 0; tries < 100; tries++) {
        for (int i = 0; i < 6; i++) tmpl[l - 6 + i] = cs[kai_win_random() % (sizeof cs - 1)];
        int fd = kai_win_open(tmpl, _O_RDWR | _O_CREAT | _O_EXCL, 0600);
        if (fd >= 0 || errno != EEXIST) return fd;
    }
    return -1;
}

/* Positioned read that leaves the file offset alone, like POSIX pread. */
ssize_t kai_win_pread(int fd, void *buf, size_t n, long long off) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    if (h == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    ov.Offset = (DWORD)((unsigned long long)off & 0xffffffffu);
    ov.OffsetHigh = (DWORD)((unsigned long long)off >> 32);
    DWORD got = 0;
    if (!ReadFile(h, buf, (DWORD)n, &got, &ov)) {
        if (GetLastError() == ERROR_HANDLE_EOF) return 0;
        return set_errno_from_win();
    }
    return (ssize_t)got;
}

int kai_win_dprintf(int fd, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = _vscprintf(fmt, ap);
    va_end(ap);
    if (n < 0) return -1;
    char *s = malloc((size_t)n + 1);
    if (!s) return -1;
    va_start(ap, fmt);
    vsnprintf(s, (size_t)n + 1, fmt, ap);
    va_end(ap);
    int w = _write(fd, s, (unsigned)n);
    free(s);
    return w;
}

/* musl's regerror.c is not vendored; the messages Kai shows for a bad rule. */
size_t regerror(int e, const regex_t *preg, char *buf, size_t size) {
    (void)preg;
    static const char *const msg[] = {
        "No error", "No match", "Invalid regexp", "Unknown collating element",
        "Unknown character class name", "Trailing backslash", "Invalid back reference",
        "Missing ']'", "Missing ')'", "Missing '}'", "Invalid contents of {}",
        "Invalid character range", "Out of memory", "Repetition not preceded by valid expression"};
    const char *m = (e >= 0 && e < (int)(sizeof msg / sizeof msg[0])) ? msg[e] : "Unknown error";
    if (size) kai_strlcpy(buf, m, size);
    return strlen(m) + 1;
}

/* ----------------------------------------------------------- directories */

struct kai_win_dir {
    HANDLE h;
    WIN32_FIND_DATAW fd;
    int first;
    struct dirent ent;
};

DIR *opendir(const char *path) {
    size_t l = strlen(path);
    char *pat = malloc(l + 3);
    if (!pat) { errno = ENOMEM; return NULL; }
    memcpy(pat, path, l);
    if (l && path[l - 1] != '/' && path[l - 1] != '\\') pat[l++] = '/';
    pat[l++] = '*';
    pat[l] = '\0';
    wchar_t *w = wide(pat);
    free(pat);
    if (!w) { errno = ENOENT; return NULL; }
    DIR *d = calloc(1, sizeof *d);
    if (!d) { free(w); errno = ENOMEM; return NULL; }
    d->h = FindFirstFileExW(w, FindExInfoBasic, &d->fd, FindExSearchNameMatch, NULL, 0);
    free(w);
    if (d->h == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        free(d);
        if (e == ERROR_DIRECTORY) { errno = ENOTDIR; return NULL; }
        SetLastError(e);
        set_errno_from_win();
        return NULL;
    }
    d->first = 1;
    return d;
}

struct dirent *readdir(DIR *d) {
    if (!d) return NULL;
    if (!d->first && !FindNextFileW(d->h, &d->fd)) return NULL;
    d->first = 0;
    char *s = narrow(d->fd.cFileName);
    kai_strlcpy(d->ent.d_name, s ? s : "", sizeof d->ent.d_name);
    free(s);
    DWORD a = d->fd.dwFileAttributes;
    d->ent.d_type = (a & FILE_ATTRIBUTE_REPARSE_POINT) ? DT_LNK : (a & FILE_ATTRIBUTE_DIRECTORY) ? DT_DIR : DT_REG;
    return &d->ent;
}

int closedir(DIR *d) {
    if (!d) return -1;
    FindClose(d->h);
    free(d);
    return 0;
}

/* --------------------------------------------------------------- flock */

int flock(int fd, int op) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    if (h == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    if (op & LOCK_UN) return UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov) ? 0 : set_errno_from_win();
    DWORD fl = (op & LOCK_EX) ? LOCKFILE_EXCLUSIVE_LOCK : 0;
    if (op & LOCK_NB) fl |= LOCKFILE_FAIL_IMMEDIATELY;
    if (LockFileEx(h, fl, 0, MAXDWORD, MAXDWORD, &ov)) return 0;
    if (GetLastError() == ERROR_LOCK_VIOLATION || GetLastError() == ERROR_IO_PENDING) { errno = EWOULDBLOCK; return -1; }
    return set_errno_from_win();
}

/* -------------------------------------------------------------- fnmatch */

/* POSIX fnmatch for the flags Kai uses (0, FNM_CASEFOLD, FNM_PATHNAME,
 * FNM_NOESCAPE, FNM_PERIOD): * ? [set] [!set] [a-z] and \ escapes. */
static int fold(int c, int cf) { return cf ? tolower(c) : c; }

int fnmatch(const char *p, const char *s, int flags) {
    int cf = flags & FNM_CASEFOLD, pn = flags & FNM_PATHNAME, ne = flags & FNM_NOESCAPE;
    const char *start = s;
    while (*p) {
        if ((flags & FNM_PERIOD) && *s == '.' && (s == start || (pn && s[-1] == '/')) && *p != '.')
            return FNM_NOMATCH;
        switch (*p) {
        case '?':
            if (!*s || (pn && *s == '/')) return FNM_NOMATCH;
            p++; s++;
            break;
        case '*': {
            while (*p == '*') p++;
            if (!*p) return (pn && strchr(s, '/')) ? FNM_NOMATCH : 0;
            for (; *s; s++) {
                if (fnmatch(p, s, flags & ~FNM_PERIOD) == 0) return 0;
                if (pn && *s == '/') return FNM_NOMATCH;
            }
            return fnmatch(p, s, flags & ~FNM_PERIOD) == 0 ? 0 : FNM_NOMATCH;
        }
        case '[': {
            if (!*s || (pn && *s == '/')) return FNM_NOMATCH;
            const char *q = p + 1;
            int neg = (*q == '!' || *q == '^');
            if (neg) q++;
            int hit = 0, c = fold((unsigned char)*s, cf);
            const char *set = q;
            while (*q && (*q != ']' || q == set)) {
                int lo = (unsigned char)*q, hi;
                if (lo == '\\' && !ne && q[1]) lo = (unsigned char)*++q;
                if (q[1] == '-' && q[2] && q[2] != ']') {
                    hi = (unsigned char)q[2];
                    q += 3;
                } else { hi = lo; q++; }
                if (c >= fold(lo, cf) && c <= fold(hi, cf)) hit = 1;
            }
            if (*q != ']') {   /* no closing bracket: a literal '[' */
                if (*s != '[') return FNM_NOMATCH;
                p++; s++;
                break;
            }
            if (hit == neg) return FNM_NOMATCH;
            p = q + 1; s++;
            break;
        }
        case '\\':
            if (!ne && p[1]) p++;
            /* fall through */
        default:
            if (fold((unsigned char)*p, cf) != fold((unsigned char)*s, cf)) return FNM_NOMATCH;
            p++; s++;
        }
    }
    return *s ? FNM_NOMATCH : 0;
}

/* -------------------------------------------------------------- strings */

char *kai_win_strcasestr(const char *h, const char *n) {
    size_t nl = strlen(n);
    for (; *h; h++) if (!_strnicmp(h, n, nl)) return (char *)h;
    return nl ? NULL : (char *)h;
}

int kai_win_asprintf(char **out, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = _vscprintf(fmt, ap);
    va_end(ap);
    *out = NULL;
    if (n < 0) return -1;
    char *s = malloc((size_t)n + 1);
    if (!s) return -1;
    va_start(ap, fmt);
    vsnprintf(s, (size_t)n + 1, fmt, ap);
    va_end(ap);
    *out = s;
    return n;
}

char *kai_win_strndup(const char *s, size_t n) {
    size_t l = strnlen(s, n);
    char *r = malloc(l + 1);
    if (r) { memcpy(r, s, l); r[l] = '\0'; }
    return r;
}

/* Only the format Kai uses: "%Y-%m-%dT%H:%M:%SZ" (and any literal text). */
char *kai_win_strptime(const char *s, const char *fmt, struct tm *tm) {
    memset(tm, 0, sizeof *tm);
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            if (*s != *fmt) return NULL;
            s++;
            continue;
        }
        fmt++;
        int width = *fmt == 'Y' ? 4 : 2, v = 0, i = 0;
        for (; i < width && isdigit((unsigned char)*s); i++, s++) v = v * 10 + (*s - '0');
        if (!i) return NULL;
        switch (*fmt) {
        case 'Y': tm->tm_year = v - 1900; break;
        case 'm': tm->tm_mon = v - 1; break;
        case 'd': tm->tm_mday = v; break;
        case 'H': tm->tm_hour = v; break;
        case 'M': tm->tm_min = v; break;
        case 'S': tm->tm_sec = v; break;
        default: return NULL;
        }
    }
    return (char *)s;
}

/* ---------------------------------------------------------------- time */

int kai_win_clock_gettime(int clk, struct timespec *ts) {
    if (clk == CLOCK_MONOTONIC) {
        LARGE_INTEGER f, c;
        QueryPerformanceFrequency(&f);
        QueryPerformanceCounter(&c);
        ts->tv_sec = (time_t)(c.QuadPart / f.QuadPart);
        ts->tv_nsec = (long)((c.QuadPart % f.QuadPart) * 1000000000LL / f.QuadPart);
        return 0;
    }
    return timespec_get(ts, TIME_UTC) ? 0 : -1;
}

int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    tv->tv_sec = (long)ts.tv_sec;
    tv->tv_usec = ts.tv_nsec / 1000;
    return 0;
}

unsigned int kai_win_sleep(unsigned int s) { Sleep(s * 1000u); return 0; }
int kai_win_usleep(unsigned long us) { Sleep((DWORD)((us + 999) / 1000)); return 0; }

/* -------------------------------------------------------------- process */

int kai_win_getppid(void) {
    DWORD me = GetCurrentProcessId(), parent = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof pe;
    for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
        if (pe.th32ProcessID == me) { parent = pe.th32ParentProcessID; break; }
    CloseHandle(snap);
    return (int)parent;
}

int kai_win_kill(int pid, int sig) {
    if (sig == 0) {
        if (kai_plat_pid_alive(pid)) return 0;
        errno = ESRCH;
        return -1;
    }
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
    if (!h) { errno = ESRCH; return -1; }
    BOOL ok = TerminateProcess(h, 128u + (unsigned)sig);
    CloseHandle(h);
    return ok ? 0 : set_errno_from_win();
}

pid_t waitpid(pid_t pid, int *status, int options) {
    HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!h) { errno = ECHILD; return -1; }
    DWORD w = WaitForSingleObject(h, (options & WNOHANG) ? 0 : INFINITE);
    if (w != WAIT_OBJECT_0) { CloseHandle(h); return 0; }
    DWORD code = 0;
    GetExitCodeProcess(h, &code);
    CloseHandle(h);
    if (status) *status = (int)(code & 0xff);
    return pid;
}

struct passwd *getpwuid(uid_t uid) {
    (void)uid;
    static struct passwd pw;
    static char name[256], dir[PATH_MAX];
    wchar_t wn[256];
    DWORD n = 256;
    if (GetUserNameW(wn, &n)) {
        char *s = narrow(wn);
        kai_strlcpy(name, s ? s : "user", sizeof name);
        free(s);
    } else kai_strlcpy(name, "user", sizeof name);
    kai_strlcpy(dir, kai_plat_home(), sizeof dir);
    pw.pw_name = name;
    pw.pw_dir = dir;
    pw.pw_uid = 0;
    return &pw;
}

char *readpassphrase(const char *prompt, char *buf, size_t n, int flags) {
    (void)flags;
    HANDLE in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (in == INVALID_HANDLE_VALUE) { errno = ENOTTY; return NULL; }
    fputs(prompt, stderr);
    fflush(stderr);
    DWORD mode = 0;
    GetConsoleMode(in, &mode);
    SetConsoleMode(in, mode & ~(DWORD)ENABLE_ECHO_INPUT);
    wchar_t wb[512];
    DWORD got = 0;
    BOOL ok = ReadConsoleW(in, wb, 511, &got, NULL);
    SetConsoleMode(in, mode);
    CloseHandle(in);
    fputs("\n", stderr);
    if (!ok) { errno = EIO; return NULL; }
    while (got && (wb[got - 1] == L'\n' || wb[got - 1] == L'\r')) got--;
    wb[got] = 0;
    char *s = narrow(wb);
    SecureZeroMemory(wb, sizeof wb);
    if (!s) return NULL;
    kai_strlcpy(buf, s, n);
    SecureZeroMemory(s, strlen(s));
    free(s);
    return buf;
}

/* ---------------------------------------------------------------- locks */

int pthread_rwlock_init(pthread_rwlock_t *l, const void *attr) { (void)attr; InitializeSRWLock((PSRWLOCK)&l->p); l->excl = 0; return 0; }
int pthread_rwlock_destroy(pthread_rwlock_t *l) { (void)l; return 0; }
int pthread_rwlock_rdlock(pthread_rwlock_t *l) { AcquireSRWLockShared((PSRWLOCK)&l->p); return 0; }
int pthread_rwlock_wrlock(pthread_rwlock_t *l) { AcquireSRWLockExclusive((PSRWLOCK)&l->p); l->excl = 1; return 0; }
/* While a writer holds the lock there are no readers, so excl tells which
 * side this unlock releases. */
int pthread_rwlock_unlock(pthread_rwlock_t *l) {
    if (l->excl) { l->excl = 0; ReleaseSRWLockExclusive((PSRWLOCK)&l->p); }
    else ReleaseSRWLockShared((PSRWLOCK)&l->p);
    return 0;
}
int pthread_mutex_lock(pthread_mutex_t *m) { AcquireSRWLockExclusive((PSRWLOCK)m); return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { ReleaseSRWLockExclusive((PSRWLOCK)m); return 0; }
