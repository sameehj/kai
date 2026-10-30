/*
 * Kai — Preview 1 terminal grants (experience spec v2.1, A.6).
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 *   kai rules                                        what each agent may do, and why
 *   kai allow-file <path> --read|--write --agent A [--for 1h]
 *   kai allow-fetch <domain> --agent A [--for 1h]
 *   kai allow-mcp <server> [<tool>] --agent A [--for 1h]
 *   kai allow-upload <file> --to <host> --agent A [--for 1h]
 *   kai allow-capture --app <name> --agent A [--for 15m]
 *   kai block <host> [--agent A]
 *   kai undo
 *
 * Every grant is exactly agent + operation + target + expiry, and covers only
 * the checks its output lists. Files are stored canonical (absolute, symlinks
 * resolved) with their device and inode: if the path later names a different
 * file, a read or upload grant doesn't apply. Lower assurance, and said so:
 * these live in <kai home>/agent-rules.json, which a program with the user's
 * permissions can edit. Refusing inside an agent's process tree is a
 * convenience, not a security boundary. With the Kai app installed, the app
 * keeps the rules ("Change this in Kai").
 */
#include "internal.h"
#include "kai.h"
#include "cJSON.h"

#include <ctype.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pwd.h>
#include <readpassphrase.h>
#endif

#define LIMIT_LINE "Preview 1 can't stop a program with your permissions from editing Kai's rules; " \
                   "the app release adds a protected writer."

static const char *rules_path(void) {
    static char buf[1200];
    snprintf(buf, sizeof buf, "%s/agent-rules.json", kai_home());
    return buf;
}
static const char *history_path(void) {
    static char buf[1200];
    snprintf(buf, sizeof buf, "%s/agent-rules.history", kai_home());
    return buf;
}

static cJSON *load_rules(void) {
    size_t n = 0;
    char *t = kai_read_file(rules_path(), 1 << 20, &n);
    cJSON *a = t ? cJSON_Parse(t) : NULL;
    free(t);
    if (!cJSON_IsArray(a)) { cJSON_Delete(a); a = cJSON_CreateArray(); }
    return a;
}

static int write_atomic(const char *path, const char *data) {
    char tmp[1300];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    int ok = fputs(data, f) >= 0;
    ok = (fclose(f) == 0) && ok;
    chmod(tmp, 0600);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static void push_history(void) {
    size_t n = 0;
    char *t = kai_read_file(rules_path(), 1 << 20, &n);
    cJSON *a = t ? cJSON_Parse(t) : NULL;
    free(t);
    char *line = cJSON_PrintUnformatted(cJSON_IsArray(a) ? a : NULL);
    cJSON_Delete(a);
    FILE *f = fopen(history_path(), "a");
    if (f) { fprintf(f, "%s\n", line ? line : "[]"); fclose(f); chmod(history_path(), 0600); }
    free(line);
}

static int save_rules(cJSON *a) {
    mkdir(kai_home(), 0700);
    char *s = cJSON_Print(a);
    int rc = s ? write_atomic(rules_path(), s) : -1;
    free(s);
    return rc;
}

static void lower(char *s) { for (; *s; s++) *s = (char)tolower((unsigned char)*s); }

static const char *jstr(const cJSON *o, const char *k) {
    const char *v = cJSON_GetStringValue(cJSON_GetObjectItem(o, k));
    return v ? v : "";
}
static double jnum(const cJSON *o, const char *k) { return cJSON_GetNumberValue(cJSON_GetObjectItem(o, k)); }

/* Canonical path: relative to base (or the current directory), symlinks
 * resolved. For a path that doesn't exist yet (a write), the folder is
 * resolved and the name appended. 1 ok. */
/* When this file was created: device + inode alone don't identify a file,
 * since a freed inode number can come straight back for a new file (ext4 does
 * at once; on macOS, HFS+, exFAT, FAT and network volumes can; APFS numbers
 * rarely). macOS: st_birthtimespec. Linux: statx btime. Neither: ctime, which
 * is stricter (an edit also ends the grant). */
static void file_birth(const char *path, const struct stat *st, long long *sec, long long *nsec) {
#if defined(__APPLE__)
    (void)path;
    *sec = (long long)st->st_birthtimespec.tv_sec; *nsec = (long long)st->st_birthtimespec.tv_nsec;
#else
#if defined(__linux__) && defined(STATX_BTIME)
    struct statx sx;
    if (statx(AT_FDCWD, path, 0, STATX_BTIME, &sx) == 0 && (sx.stx_mask & STATX_BTIME)) {
        *sec = (long long)sx.stx_btime.tv_sec; *nsec = (long long)sx.stx_btime.tv_nsec; return;
    }
#else
    (void)path;
#endif
    *sec = (long long)st->st_ctim.tv_sec; *nsec = (long long)st->st_ctim.tv_nsec;
#endif
}

static int canonical(const char *path, const char *base, char *out, size_t n) {
    char joined[PATH_MAX * 2];
    if (!path || !*path) return 0;
    if (path[0] == '~' && (path[1] == '/' || !path[1])) {
        const char *h = getenv("HOME");
        snprintf(joined, sizeof joined, "%s%s", h ? h : "", path + 1);
    } else if (path[0] == '/') {
        kai_strlcpy(joined, path, sizeof joined);
    } else {
        char cwd[PATH_MAX];
        if (!base && !getcwd(cwd, sizeof cwd)) return 0;
        snprintf(joined, sizeof joined, "%s/%s", base ? base : cwd, path);
    }
    char r[PATH_MAX];
    if (realpath(joined, r)) { kai_strlcpy(out, r, n); return 1; }
    char dir[PATH_MAX * 2];
    kai_strlcpy(dir, joined, sizeof dir);
    char *slash = strrchr(dir, '/');
    if (!slash) return 0;
    *slash = '\0';
    if (!realpath(*dir ? dir : "/", r)) return 0;
    snprintf(out, n, "%s/%s", r, slash + 1);
    return 1;
}

int kai_cli_grant_add(int allow, const char *op, const char *agent, const char *target, const char *to,
                      long long until, const char *base, char *err, size_t errlen) {
    if (err && errlen) err[0] = '\0';
    if (!op || !agent || !*agent || !target || !*target) return -1;
    int file = !strcmp(op, "read") || !strcmp(op, "write") || !strcmp(op, "upload");
    char t[PATH_MAX];
    struct stat st;
    long long dev = 0, ino = 0, bsec = 0, bnsec = 0;
    if (file) {
        if (!canonical(target, base, t, sizeof t)) { if (err) snprintf(err, errlen, "can't find %s", target); return -1; }
        if (strcmp(op, "write") != 0) {
            if (stat(t, &st) != 0) { if (err) snprintf(err, errlen, "%s doesn't exist", t); return -1; }
            dev = (long long)st.st_dev; ino = (long long)st.st_ino;
            file_birth(t, &st, &bsec, &bnsec);
        }
    } else {
        kai_strlcpy(t, target, sizeof t);
        if (strcmp(op, "mcp") != 0 && strcmp(op, "exact") != 0) lower(t);   /* exact: a command glob, as written */
    }
    char tohost[256] = "";
    if (to) { kai_strlcpy(tohost, to, sizeof tohost); if (!strcmp(op, "upload")) lower(tohost); }
    mkdir(kai_home(), 0700);
    push_history();
    cJSON *a = load_rules();
    for (int i = cJSON_GetArraySize(a) - 1; i >= 0; i--) {   /* one rule per agent+op+target+to */
        cJSON *r = cJSON_GetArrayItem(a, i);
        if (!strcmp(jstr(r, "agent"), agent) && !strcmp(jstr(r, "op"), op) &&
            !strcmp(jstr(r, "target"), t) && !strcmp(jstr(r, "to"), tohost))
            cJSON_DeleteItemFromArray(a, i);
    }
    cJSON *r = cJSON_CreateObject();
    cJSON_AddStringToObject(r, "kind", allow ? "allow" : "block");
    cJSON_AddStringToObject(r, "op", op);
    cJSON_AddStringToObject(r, "agent", agent);
    cJSON_AddStringToObject(r, "target", t);
    cJSON_AddStringToObject(r, "to", tohost);
    cJSON_AddNumberToObject(r, "dev", (double)dev);
    cJSON_AddNumberToObject(r, "ino", (double)ino);
    if (bsec || bnsec) {   /* seconds and nanoseconds apart: a double can't hold ns since 1970 exactly */
        cJSON_AddNumberToObject(r, "bsec", (double)bsec);
        cJSON_AddNumberToObject(r, "bnsec", (double)bnsec);
    }
    cJSON_AddNumberToObject(r, "until", (double)until);
    cJSON_AddNumberToObject(r, "created", (double)time(NULL));
    cJSON_AddItemToArray(a, r);
    int rc = save_rules(a);
    cJSON_Delete(a);
    return rc;
}

int kai_cli_grant_remove(const char *op, const char *agent, const char *target) {
    if (!op || !agent || !target) return -1;
    char t[256];
    kai_strlcpy(t, target, sizeof t);
    lower(t);
    cJSON *a = load_rules();
    int removed = 0;
    for (int i = cJSON_GetArraySize(a) - 1; i >= 0; i--) {
        cJSON *r = cJSON_GetArrayItem(a, i);
        if (!strcmp(jstr(r, "kind"), "allow") && !strcmp(jstr(r, "op"), op) && !strcmp(jstr(r, "agent"), agent) &&
            !strcmp(jstr(r, "target"), t)) { cJSON_DeleteItemFromArray(a, i); removed = 1; }
    }
    int rc = -1;
    if (removed) { push_history(); rc = save_rules(a); }
    cJSON_Delete(a);
    return rc;
}

int kai_agent_rule_add(int kind, const char *agent, const char *host, long long until) {
    return kai_cli_grant_add(kind == KAI_AGENT_RULE_BLOCK ? 0 : 1, kind == KAI_AGENT_RULE_BLOCK ? "reach" : "fetch",
                             agent, host, NULL, until, NULL, NULL, 0);
}

int kai_agent_rule_undo(void) {
    size_t n = 0;
    char *t = kai_read_file(history_path(), 8u << 20, &n);
    if (!t || !n) { free(t); return -1; }
    while (n && t[n - 1] == '\n') t[--n] = '\0';
    char *last = strrchr(t, '\n');
    char *prev = last ? last + 1 : t;
    cJSON *a = cJSON_Parse(prev);
    int rc = cJSON_IsArray(a) ? save_rules(a) : -1;
    cJSON_Delete(a);
    if (rc == 0) {
        if (last) { last[1] = '\0'; rc = write_atomic(history_path(), t); }
        else unlink(history_path());
    }
    free(t);
    return rc;
}

static int host_covers(const char *rule, const char *host, int subdomains) {
    size_t rl = strlen(rule), hl = strlen(host);
    if (rl == hl) return !strcasecmp(rule, host);
    return subdomains && hl > rl && host[hl - rl - 1] == '.' && !strcasecmp(host + hl - rl, rule);
}

static int live(const cJSON *r, long long now) {
    double until = jnum(r, "until");
    return !(until > 0 && (long long)until <= now);
}

/* A host you blocked (subdomains too). KAI_AGENT_RULE_BLOCK or 0. */
int kai_agent_rule_for(const char *agent, const char *host, long long now) {
    if (!agent || !host || !*host) return 0;
    cJSON *a = load_rules();
    int found = 0;
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        if (strcmp(jstr(r, "kind"), "block") || strcmp(jstr(r, "op"), "reach") || !live(r, now)) continue;
        const char *ra = jstr(r, "agent");
        if (strcmp(ra, "*") && strcmp(ra, agent)) continue;
        if (host_covers(jstr(r, "target"), host, 1)) { found = KAI_AGENT_RULE_BLOCK; break; }
    }
    cJSON_Delete(a);
    return found;
}

int kai_cli_grant_allows(const char *op, const char *agent, const char *target, const char *to,
                         const char *cwd, long long now) {
    if (!op || !agent || !target || !*target) return 0;
    int file = !strcmp(op, "read") || !strcmp(op, "write") || !strcmp(op, "upload");
    char t[PATH_MAX];
    struct stat st;
    int have_st = 0;
    if (file) {
        if (!canonical(target, cwd, t, sizeof t)) return 0;
        have_st = stat(t, &st) == 0;
    } else {
        kai_strlcpy(t, target, sizeof t);
        if (strcmp(op, "mcp") != 0) lower(t);
    }
    cJSON *a = load_rules();
    int ok = 0;
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        if (strcmp(jstr(r, "kind"), "allow") || strcmp(jstr(r, "op"), op) || !live(r, now)) continue;
        if (strcmp(jstr(r, "agent"), agent)) continue;          /* one agent; never "*" */
        if (strcmp(jstr(r, "target"), t)) continue;            /* exact */
        const char *rto = jstr(r, "to");
        if (!strcmp(op, "mcp")) { if (*rto && (!to || strcmp(rto, to))) continue; }   /* "" = any tool */
        else if (!strcmp(op, "upload")) { if (!to || strcasecmp(rto, to)) continue; }
        if (file && strcmp(op, "write") != 0) {               /* the same file it was granted on */
            if (!have_st || (long long)st.st_dev != (long long)jnum(r, "dev") ||
                (long long)st.st_ino != (long long)jnum(r, "ino")) continue;
            if (cJSON_GetObjectItem(r, "bsec")) {               /* ...and born when it was: not a new file on a reused inode */
                long long bs = 0, bn = 0;
                file_birth(t, &st, &bs, &bn);
                if (bs != (long long)jnum(r, "bsec") || bn != (long long)jnum(r, "bnsec")) continue;
            }
        }
        ok = 1; break;
    }
    cJSON_Delete(a);
    return ok;
}

/* The end of this agent's live allow for op + target: the latest "until",
 * -1 for one that never ends, 0 for none. */
long long kai_cli_grant_until(const char *op, const char *agent, const char *target, long long now) {
    if (!op || !agent || !target) return 0;
    char t[256];
    kai_strlcpy(t, target, sizeof t);
    lower(t);
    cJSON *a = load_rules();
    long long best = 0;
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        if (strcmp(jstr(r, "kind"), "allow") || strcmp(jstr(r, "op"), op) || !live(r, now)) continue;
        if (strcmp(jstr(r, "agent"), agent) || strcmp(jstr(r, "target"), t)) continue;
        long long u = (long long)jnum(r, "until");
        if (u <= 0) { best = -1; break; }
        if (u > best) best = u;
    }
    cJSON_Delete(a);
    return best;
}

/* An exact-command allow (op "exact": target = a glob over the command, to =
 * the rule it lifts) that ends within max_secs (0 = any end). */
int kai_cli_command_granted(const char *agent, const char *rule, const char *cmd, long long max_secs, long long now) {
    if (!agent || !rule || !cmd) return 0;
    cJSON *a = load_rules();
    int ok = 0;
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        if (strcmp(jstr(r, "kind"), "allow") || strcmp(jstr(r, "op"), "exact") || !live(r, now)) continue;
        if (strcmp(jstr(r, "agent"), agent) || strcmp(jstr(r, "to"), rule)) continue;
        long long u = (long long)jnum(r, "until");
        if (max_secs > 0 && (u <= 0 || u - now > max_secs)) continue;   /* longer than allowed: ignored */
        if (fnmatch(jstr(r, "target"), cmd, 0) == 0) { ok = 1; break; }
    }
    cJSON_Delete(a);
    return ok;
}

/* ---- the hosts a shell command reaches ---- */

static int add_host(char hosts[][256], int n, int max, const char *s, size_t len) {
    if (!len || len >= 256 || n >= max) return n;
    char h[256];
    memcpy(h, s, len); h[len] = '\0';
    lower(h);
    if (!strchr(h, '.') && strcmp(h, "localhost") != 0) return n;
    for (int i = 0; i < n; i++) if (!strcmp(hosts[i], h)) return n;
    kai_strlcpy(hosts[n], h, 256);
    return n + 1;
}

static int hostch(char c) { return isalnum((unsigned char)c) || c == '.' || c == '-'; }

static size_t url_host(const char *u, const char **start) {
    const char *h = strstr(u, "://");
    h = h ? h + 3 : u;
    const char *at = strpbrk(h, "@/");
    if (at && *at == '@') h = at + 1;
    size_t l = 0;
    while (hostch(h[l])) l++;
    *start = h;
    return l;
}

typedef struct { char (*hosts)[256]; int n, max; } host_acc;

static void walk_hosts(char **argv, int argc, void *ud) {
    host_acc *acc = ud;
    int i = kai_shell_command_start(argv, argc);
    if (i >= argc) return;
    const char *b = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
    int netcat = !strcmp(b, "nc") || !strcmp(b, "ncat") || !strcmp(b, "netcat") || !strcmp(b, "telnet");
    int remote = !strcmp(b, "scp") || !strcmp(b, "rsync") || !strcmp(b, "ssh") || !strcmp(b, "sftp");
    int netcat_done = 0;
    for (int k = i + 1; k < argc; k++) {
        const char *a = argv[k];
        if (strstr(a, "://")) {
            const char *h; size_t l = url_host(a, &h);
            acc->n = add_host(acc->hosts, acc->n, acc->max, h, l);
            continue;
        }
        if (remote && a[0] != '-') {
            const char *h = strchr(a, '@') ? strchr(a, '@') + 1 : a;
            size_t l = 0;
            while (hostch(h[l])) l++;
            if (l && (h[l] == ':' || (h[l] == '\0' && strchr(a, '@'))))
                acc->n = add_host(acc->hosts, acc->n, acc->max, h, l);
            continue;
        }
        if (netcat && !netcat_done && a[0] != '-') {
            size_t l = 0;
            while (hostch(a[l])) l++;
            if (l && a[l] == '\0') { acc->n = add_host(acc->hosts, acc->n, acc->max, a, l); netcat_done = 1; }
        }
    }
}

int kai_command_hosts(const char *cmd, char hosts[][256], int max) {
    if (!cmd || max <= 0) return 0;
    host_acc acc = {hosts, 0, max};
    kai_shell_walk(cmd, walk_hosts, NULL, &acc);
    return acc.n;
}

/* ---- A.5/A.6: what an upload command sends, when Kai can tell ----
 * Only a single simple command, in one of these forms:
 *   curl ... (-d|--data|--data-binary|-F name=)@FILE ... URL
 *   curl ... (-T|--upload-file) FILE ... URL
 *   scp [opts] FILE [user@]HOST:PATH
 * Anything else (pipes, redirects, several commands, files or hosts) isn't
 * identified, so no narrow allow is offered or honoured. */
typedef struct { int ncmd; char file[PATH_MAX]; char host[256]; char form[16]; int nfile, nhost; } up_acc;

static void walk_upload(char **argv, int argc, void *ud) {
    up_acc *u = ud;
    u->ncmd++;
    int i = kai_shell_command_start(argv, argc);
    if (i >= argc) return;
    const char *b = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
    if (!strcmp(b, "curl")) {
        kai_strlcpy(u->form, "curl", sizeof u->form);
        for (int k = i + 1; k < argc; k++) {
            const char *a = argv[k];
            const char *f = NULL;
            if ((!strcmp(a, "-d") || !strcmp(a, "--data") || !strcmp(a, "--data-binary") ||
                 !strcmp(a, "-F") || !strcmp(a, "--form")) && k + 1 < argc) {
                const char *v = argv[++k];
                const char *at = strchr(v, '@');
                if (at && (at == v || !strcmp(a, "-F") || !strcmp(a, "--form"))) f = at + 1;
            } else if ((!strcmp(a, "-T") || !strcmp(a, "--upload-file")) && k + 1 < argc) {
                f = argv[++k];
            } else if (strstr(a, "://")) {
                const char *h; size_t l = url_host(a, &h);
                if (l && l < sizeof u->host) { memcpy(u->host, h, l); u->host[l] = '\0'; u->nhost++; }
            }
            if (f && *f) {
                char tmp[PATH_MAX];
                kai_strlcpy(tmp, f, sizeof tmp);
                char *semi = strchr(tmp, ';');            /* -F x=@file;type=... */
                if (semi) *semi = '\0';
                kai_strlcpy(u->file, tmp, sizeof u->file); u->nfile++;
            }
        }
    } else if (!strcmp(b, "scp")) {
        kai_strlcpy(u->form, "scp", sizeof u->form);
        for (int k = i + 1; k < argc; k++) {
            const char *a = argv[k];
            if (a[0] == '-') { if (!strcmp(a, "-P") || !strcmp(a, "-i") || !strcmp(a, "-o")) k++; continue; }
            const char *colon = strchr(a, ':');
            if (colon) {
                const char *at = strchr(a, '@');
                const char *h = at && at < colon ? at + 1 : a;
                size_t l = (size_t)(colon - h);
                if (l && l < sizeof u->host) { memcpy(u->host, h, l); u->host[l] = '\0'; u->nhost++; }
            } else { kai_strlcpy(u->file, a, sizeof u->file); u->nfile++; }
        }
    }
}

int kai_upload_parse(const char *cmd, char *file, size_t fn, char *host, size_t hn, char *form, size_t fmn) {
    if (file && fn) file[0] = '\0';
    if (host && hn) host[0] = '\0';
    if (form && fmn) form[0] = '\0';
    if (!cmd || strpbrk(cmd, "|`$<>\n")) return 0;   /* one simple command only */
    up_acc u;
    memset(&u, 0, sizeof u);
    kai_shell_walk(cmd, walk_upload, NULL, &u);
    if (u.ncmd != 1 || u.nfile != 1 || u.nhost != 1 || !u.form[0]) return 0;
    lower(u.host);
    if (file) kai_strlcpy(file, u.file, fn);
    if (host) kai_strlcpy(host, u.host, hn);
    if (form) kai_strlcpy(form, u.form, fmn);
    return 1;
}

/* ---- screen and app control (release batch 16) ----
 * The commands an agent runs to capture the screen, microphone or camera, or
 * to drive another app. Each is named by an app: the app a script tells, or
 * the program that captures, and grants are per app. macOS grants these
 * permissions per app, so an agent inherits whatever its terminal or editor
 * holds. A program the agent writes can call the capture APIs itself; that
 * isn't seen here. */
typedef struct { char what[96]; char app[64]; int osascript; } cap_acc;

/* Case-insensitive strstr (strcasestr isn't declared under _POSIX_C_SOURCE on glibc). */
static const char *ci_find(const char *h, const char *n) {
    size_t nl = strlen(n);
    for (; h && *h; h++) if (strncasecmp(h, n, nl) == 0) return h;
    return NULL;
}

static int has_word(const char *s, const char *w) { return s && ci_find(s, w) != NULL; }

static int system_audio(const char *s) {
    return has_word(s, "blackhole") || has_word(s, "soundflower") || has_word(s, "loopback");
}

/* The quoted name after `mark` (tell application "X", Application('X')). */
static int quoted_after(const char *text, const char *mark, char *out, size_t n) {
    size_t ml = strlen(mark);
    for (const char *t = text; t && (t = ci_find(t, mark)) != NULL; t += ml) {
        const char *q = t + ml;
        while (*q == ' ' || *q == '\\') q++;
        if (*q != '"' && *q != '\'') continue;
        char qc = *q++;
        size_t l = 0;
        while (q[l] && q[l] != qc && q[l] != '\\') l++;
        if (!l || !q[l] || l >= n) continue;
        memcpy(out, q, l);
        out[l] = '\0';
        return 1;
    }
    return 0;
}

/* Apps that run whatever they're told outside Kai's checks: terminals and
 * System Events. Their allows need owner authentication and last at most
 * KAI_TERMINAL_ALLOW_MAX seconds. */
int kai_capture_app_is_terminal(const char *app) {
    static const char *const T[] = {
        "terminal", "com.apple.terminal", "iterm", "iterm2", "com.googlecode.iterm2", "warp", "dev.warp.warp-stable",
        "ghostty", "com.mitchellh.ghostty", "system events", "com.apple.systemevents", "kitty", "net.kovidgoyal.kitty",
        "alacritty", "wezterm", "hyper", "tabby",
    };
    if (!app) return 0;
    for (size_t i = 0; i < sizeof T / sizeof T[0]; i++) if (!strcasecmp(app, T[i])) return 1;
    return 0;
}

int kai_told_app(const char *text, char *out, size_t n) {
    if (out && n) out[0] = '\0';
    if (!text || !out || n < 2) return 0;
    return quoted_after(text, "tell application", out, n) || quoted_after(text, "Application(", out, n);
}

static void cap_set(cap_acc *c, const char *what, const char *app) {
    kai_strlcpy(c->what, what, sizeof c->what);
    kai_strlcpy(c->app, app, sizeof c->app);
}

static void walk_capture(char **argv, int argc, void *ud) {
    cap_acc *c = ud;
    int i = kai_shell_command_start(argv, argc);
    if (i >= argc || c->what[0]) return;
    const char *b = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
    if (!strcmp(b, "screencapture")) {
        int video = 0;
        for (int k = i + 1; k < argc; k++) if (!strcmp(argv[k], "-v") || !strcmp(argv[k], "-V")) video = 1;
        cap_set(c, video ? "record your screen" : "take a screenshot of your screen", b);
    } else if (!strcmp(b, "ffmpeg")) {
        int avf = 0; const char *in = NULL;
        for (int k = i + 1; k + 1 < argc; k++) {
            if (!strcmp(argv[k], "-f") && !strcmp(argv[k + 1], "avfoundation")) avf = 1;
            else if (!strcmp(argv[k], "-i") && avf && !in) in = argv[k + 1];
        }
        if (!avf) return;
        cap_set(c, in && system_audio(in) ? "record your Mac's sound"
                 : in && in[0] == ':' ? "record from your microphone" : "record your camera or screen", b);
    } else if (!strcmp(b, "rec") || !strcmp(b, "sox")) {
        int live = !strcmp(b, "rec");
        for (int k = i + 1; k < argc; k++) {
            if (!strcmp(argv[k], "-d") || (!strcmp(argv[k], "-t") && k + 1 < argc && !strcmp(argv[k + 1], "coreaudio")))
                live = 1;
            if (system_audio(argv[k])) { live = 2; break; }
        }
        if (live) cap_set(c, live == 2 ? "record your Mac's sound" : "record from your microphone", b);
    } else if (!strcmp(b, "imagesnap")) {
        cap_set(c, "take a photo with your camera", b);
    } else if (!strcmp(b, "cliclick")) {
        cap_set(c, "control your mouse and keyboard", b);
    } else if (!strcmp(b, "osascript")) {
        c->osascript = 1;
        for (int k = i + 1; k < argc; k++) {
            char app[64];
            if (kai_told_app(argv[k], app, sizeof app)) {
                char what[96];
                snprintf(what, sizeof what, "control %s", app);
                cap_set(c, what, app);
                return;
            }
        }
    }
}

int kai_capture_match(const char *cmd, char *what, size_t n, char *app, size_t an) {
    if (what && n) what[0] = '\0';
    if (app && an) app[0] = '\0';
    if (!cmd || !*cmd) return 0;
    cap_acc c;
    memset(&c, 0, sizeof c);
    kai_shell_walk(cmd, walk_capture, NULL, &c);
    /* a script piped or fed into osascript is in the text, not its argv */
    char told[64];
    if (!c.what[0] && c.osascript && kai_told_app(cmd, told, sizeof told)) {
        char w[96];
        snprintf(w, sizeof w, "control %s", told);
        cap_set(&c, w, told);
    }
    if (!c.what[0]) return 0;
    if (what) kai_strlcpy(what, c.what, n);
    if (app) kai_strlcpy(app, c.app, an);
    return 1;
}

/* An agent's own tool: computer use or a screenshot of the screen, named by
 * its MCP server (or the tool). A web page's screenshot in a browser tool
 * isn't the screen. */
int kai_capture_tool(const char *tool, char *what, size_t n, char *app, size_t an) {
    if (what && n) what[0] = '\0';
    if (app && an) app[0] = '\0';
    if (!tool || !*tool) return 0;
    char t[256];
    kai_strlcpy(t, tool, sizeof t);
    lower(t);
    if (strstr(t, "chrome") || strstr(t, "browser") || strstr(t, "playwright") || strstr(t, "puppeteer")) return 0;
    const char *w = strstr(t, "screenshot") || strstr(t, "screen_capture") ? "take a screenshot of your screen"
                  : strstr(t, "computer") ? "see and control your screen" : NULL;
    if (!w) return 0;
    if (what) kai_strlcpy(what, w, n);
    if (app) {
        char server[64] = "";
        const char *s = !strncmp(tool, "mcp__", 5) ? tool + 5 : NULL;
        const char *e = s ? strstr(s, "__") : NULL;
        if (e && (size_t)(e - s) < sizeof server) { memcpy(server, s, (size_t)(e - s)); server[e - s] = '\0'; }
        kai_strlcpy(app, server[0] ? server : tool, an);
    }
    return 1;
}

/* ---- the commands ---- */

int kai_app_present(void) {
    const char *e = getenv("KAI_NO_APP");
    if (e && *e == '1') return 0;
    struct stat st;
    return stat("/Applications/Kai.app/Contents/Library/SystemExtensions", &st) == 0;
}

static int under_agent(void) {
    const char *t = getenv("KAI_TEST_AS_AGENT");   /* can only make it stricter */
    if (t && *t == '1') return 1;
#ifdef KAI_TEST_DIRECT_POLICY
    return 0;   /* test-only binary (tests/cli/kai-test): the suite runs inside an agent */
#endif
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) return 0;
    char name[64]; int apid;
    int hit = kai_process_agent(p, (int)getpid(), name, sizeof name, &apid);
    kai_policy_free(p);
    return hit;
}

static const char *agent_title(const char *a) {
    if (!strcmp(a, "claude")) return "Claude Code";
    if (!strcmp(a, "codex")) return "Codex";
    if (!strcmp(a, "cursor")) return "Cursor";
    if (!strcmp(a, "*")) return "every agent";
    return a;
}

static long long parse_for(const char *s) {
    char *end = NULL;
    long long v = strtoll(s, &end, 10);
    if (v <= 0 || !end) return -1;
    if (!strcmp(end, "m")) return v * 60;
    if (!strcmp(end, "h")) return v * 3600;
    if (!strcmp(end, "d")) return v * 86400;
    return -1;
}

static int gatekeep(const char *verb) {
    if (under_agent()) {
        fprintf(stderr, "kai %s: refused. Run this in your own terminal, not from an agent.\n"
                        "(A convenience, not a security boundary.)\n", verb);
        return 3;
    }
    if (kai_app_present()) {
        fprintf(stderr, "Change this in Kai: click the blocked item in Kai's Activity (or its card).\n"
                        "(With the Kai app, the app keeps the rules.)\n");
        return 4;
    }
    return 0;
}

static void when_str(long long until, char *out, size_t n) {
    time_t t = (time_t)until; struct tm tmv; localtime_r(&t, &tmv);
    strftime(out, n, "until %H:%M", &tmv);
}

static void shorten(const char *path, char *out, size_t n) {
    const char *h = getenv("HOME");
    size_t hl = h ? strlen(h) : 0;
    if (hl && !strncmp(path, h, hl) && path[hl] == '/') snprintf(out, n, "~%s", path + hl);
    else kai_strlcpy(out, path, n);
}

/* Which agents a grant can apply to, from the coverage matrix. NULL = fine,
 * else why not. */
static const char *agent_supports(const char *op, int write, const char *agent) {
    if (!agent || (strcmp(agent, "claude") && strcmp(agent, "codex") && strcmp(agent, "cursor")))
        return "--agent takes claude, codex or cursor";
    if (!strcmp(op, "file")) {
        if (!strcmp(agent, "codex")) return "Codex has no file tool that reports to Kai (its file access goes through shell commands)";
        if (write && !strcmp(agent, "cursor")) return "Cursor doesn't report file writes to Kai";
    }
    if (!strcmp(op, "fetch") && strcmp(agent, "claude")) return "only Claude Code reports its web fetches to Kai";
    if (!strcmp(op, "mcp") && !strcmp(agent, "cursor"))
        return "Cursor's MCP calls are only checked for secrets in their arguments; there's nothing to allow";
    return NULL;
}

typedef struct { const char *target, *to, *tool, *agent; long long secs; int read, write; } args_t;

static int parse_args(const char *verb, int argc, char **argv, args_t *a, int want_two) {
    memset(a, 0, sizeof *a);
    a->secs = 3600;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--agent") && i + 1 < argc) a->agent = argv[++i];
        else if (!strcmp(argv[i], "--to") && i + 1 < argc) a->to = argv[++i];
        else if (!strcmp(argv[i], "--read")) a->read = 1;
        else if (!strcmp(argv[i], "--write")) a->write = 1;
        else if (!strcmp(argv[i], "--for") && i + 1 < argc) {
            if ((a->secs = parse_for(argv[++i])) < 0 || a->secs > 7 * 86400) {
                fprintf(stderr, "kai %s: --for takes a duration up to 7d, like 30m, 1h or 1d\n", verb); return 2;
            }
        } else if (argv[i][0] != '-' && !a->target) a->target = argv[i];
        else if (argv[i][0] != '-' && want_two && !a->tool) a->tool = argv[i];
        else { fprintf(stderr, "kai %s: unknown option %s\n", verb, argv[i]); return 2; }
    }
    return 0;
}

static int finish(const char *verb, const char *what, long long until) {
    char when[32];
    when_str(until, when, sizeof when);
    printf("%s, %s.\n", what, when);
    char d[900];
    snprintf(d, sizeof d, "kai %s: %s, %s", verb, what, when);
    kai_audit("kai", verb, "note", "terminal_grant", d);
    printf("Undo: kai undo · See all: kai rules\n%s\n", LIMIT_LINE);
    return 0;
}

int kai_cmd_allow_file(int argc, char **argv) {
    args_t a;
    int rc = parse_args("allow-file", argc, argv, &a, 0);
    if (rc) return rc;
    if (!a.target || !a.agent || a.read == a.write) {
        fprintf(stderr, "usage: kai allow-file <path> --read|--write --agent claude|cursor [--for 1h]\n"); return 2;
    }
    const char *no = agent_supports("file", a.write, a.agent);
    if (no) { fprintf(stderr, "kai allow-file: %s.\n", no); return 2; }
    if ((rc = gatekeep("allow-file"))) return rc;
    const char *op = a.read ? "read" : "write";
    long long until = (long long)time(NULL) + a.secs;
    char err[300];
    if (kai_cli_grant_add(1, op, a.agent, a.target, NULL, until, NULL, err, sizeof err) != 0) {
        fprintf(stderr, "kai allow-file: %s\n", err[0] ? err : "couldn't save the grant"); return 1;
    }
    char canon[PATH_MAX], shown[PATH_MAX];
    canonical(a.target, NULL, canon, sizeof canon);
    shorten(canon, shown, sizeof shown);
    char what[PATH_MAX + 300];
    snprintf(what, sizeof what, "Allowed %s to %s %s with its file tool (%s) only. Shell commands such as `cat` "
             "are still checked, and uploading it isn't allowed",
             agent_title(a.agent), op, shown, a.read ? (!strcmp(a.agent, "cursor") ? "file reads" : "Read")
                                                   : "Write, Edit");
    if (a.read) printf("This grant follows this exact file: if %s is replaced or re-linked, it stops applying.\n", shown);
    return finish("allow-file", what, until);
}

int kai_cmd_allow_fetch(int argc, char **argv) {
    args_t a;
    int rc = parse_args("allow-fetch", argc, argv, &a, 0);
    if (rc) return rc;
    if (!a.target || !a.agent) { fprintf(stderr, "usage: kai allow-fetch <domain> --agent claude [--for 1h]\n"); return 2; }
    const char *no = agent_supports("fetch", 0, a.agent);
    if (no) { fprintf(stderr, "kai allow-fetch: %s.\n", no); return 2; }
    if ((rc = gatekeep("allow-fetch"))) return rc;
    long long until = (long long)time(NULL) + a.secs;
    if (kai_cli_grant_add(1, "fetch", a.agent, a.target, NULL, until, NULL, NULL, 0) != 0) {
        fprintf(stderr, "kai allow-fetch: couldn't save the grant\n"); return 1;
    }
    char what[600];
    snprintf(what, sizeof what, "Allowed %s's web fetch tool to use %s (exactly this host). This doesn't make %s "
             "reachable: connections made any other way aren't governed by Kai Preview",
             agent_title(a.agent), a.target, a.target);
    return finish("allow-fetch", what, until);
}

int kai_cmd_allow_mcp(int argc, char **argv) {
    args_t a;
    int rc = parse_args("allow-mcp", argc, argv, &a, 1);
    if (rc) return rc;
    if (!a.target || !a.agent) { fprintf(stderr, "usage: kai allow-mcp <server> [<tool>] --agent claude|codex [--for 1h]\n"); return 2; }
    const char *no = agent_supports("mcp", 0, a.agent);
    if (no) { fprintf(stderr, "kai allow-mcp: %s.\n", no); return 2; }
    if ((rc = gatekeep("allow-mcp"))) return rc;
    long long until = (long long)time(NULL) + a.secs;
    if (kai_cli_grant_add(1, "mcp", a.agent, a.target, a.tool ? a.tool : "", until, NULL, NULL, 0) != 0) {
        fprintf(stderr, "kai allow-mcp: couldn't save the grant\n"); return 1;
    }
    char what[400];
    if (a.tool)
        snprintf(what, sizeof what, "Allowed %s to use the tool %s from the MCP server %s (secrets in its arguments "
                 "are still stopped)", agent_title(a.agent), a.tool, a.target);
    else
        snprintf(what, sizeof what, "Allowed %s to use every tool from the MCP server %s (secrets in their "
                 "arguments are still stopped)", agent_title(a.agent), a.target);
    return finish("allow-mcp", what, until);
}

int kai_cmd_allow_upload(int argc, char **argv) {
    args_t a;
    int rc = parse_args("allow-upload", argc, argv, &a, 0);
    if (rc) return rc;
    if (!a.target || !a.to || !a.agent) {
        fprintf(stderr, "usage: kai allow-upload <file> --to <host> --agent claude|codex|cursor [--for 1h]\n"); return 2;
    }
    const char *no = agent_supports("upload", 0, a.agent);
    if (no) { fprintf(stderr, "kai allow-upload: %s.\n", no); return 2; }
    if ((rc = gatekeep("allow-upload"))) return rc;
    long long until = (long long)time(NULL) + a.secs;
    char err[300];
    if (kai_cli_grant_add(1, "upload", a.agent, a.target, a.to, until, NULL, err, sizeof err) != 0) {
        fprintf(stderr, "kai allow-upload: %s\n", err[0] ? err : "couldn't save the grant"); return 1;
    }
    char canon[PATH_MAX], shown[PATH_MAX];
    canonical(a.target, NULL, canon, sizeof canon);
    shorten(canon, shown, sizeof shown);
    char what[PATH_MAX + 400];
    snprintf(what, sizeof what, "Allowed %s to send %s to %s, only as one simple curl or scp command that Kai "
             "can read in full", agent_title(a.agent), shown, a.to);
    return finish("allow-upload", what, until);
}

/* Owner authentication in the terminal (Preview 1, no app): the login
 * password, read from the terminal without echo and checked by Open
 * Directory. No terminal (an agent's shell) = refused. 1 ok. */
static int owner_auth(const char *why) {
#ifdef KAI_TEST_DIRECT_POLICY
    const char *t = getenv("KAI_TEST_OWNER_AUTH");   /* test-only binary: ok | fail */
    if (t) return !strcmp(t, "ok");
#endif
#ifdef __APPLE__
    struct passwd *acct = getpwuid(getuid());
    if (!acct) return 0;
    char prompt[300], pass[512];
    snprintf(prompt, sizeof prompt, "%s\nYour login password: ", why);
    if (!readpassphrase(prompt, pass, sizeof pass, RPP_REQUIRE_TTY)) return 0;
    int ok = 0;
    void *h = dlopen("/System/Library/Frameworks/OpenDirectory.framework/OpenDirectory", RTLD_LAZY);
    typedef CFTypeRef (*node_fn)(CFAllocatorRef, CFTypeRef, uint32_t, CFErrorRef *);
    typedef CFTypeRef (*rec_fn)(CFTypeRef, CFStringRef, CFStringRef, CFTypeRef, CFErrorRef *);
    typedef Boolean (*ver_fn)(CFTypeRef, CFStringRef, CFErrorRef *);
    node_fn mk = h ? (node_fn)dlsym(h, "ODNodeCreateWithNodeType") : NULL;
    rec_fn cp = h ? (rec_fn)dlsym(h, "ODNodeCopyRecord") : NULL;
    ver_fn vf = h ? (ver_fn)dlsym(h, "ODRecordVerifyPassword") : NULL;
    CFStringRef *users = h ? (CFStringRef *)dlsym(h, "kODRecordTypeUsers") : NULL;
    CFTypeRef *session = h ? (CFTypeRef *)dlsym(h, "kODSessionDefault") : NULL;
    if (mk && cp && vf && users) {
        CFTypeRef node = mk(kCFAllocatorDefault, session ? *session : NULL, 0x2201 /* kODNodeTypeAuthentication */, NULL);
        CFStringRef name = CFStringCreateWithCString(NULL, acct->pw_name, kCFStringEncodingUTF8);
        CFStringRef cf_typed = CFStringCreateWithCString(NULL, pass, kCFStringEncodingUTF8);
        CFTypeRef rec = node && name ? cp(node, *users, name, NULL, NULL) : NULL;
        ok = rec && cf_typed && vf(rec, cf_typed, NULL);
        if (rec) CFRelease(rec);
        if (cf_typed) CFRelease(cf_typed);
        if (name) CFRelease(name);
        if (node) CFRelease(node);
    }
    memset(pass, 0, sizeof pass);
    return ok;
#else
    (void)why;
    return 0;
#endif
}

int kai_cmd_allow_capture(int argc, char **argv) {
    /* --app <name> is this command's own; the rest are the usual options */
    const char *app = NULL;
    char *rest[64];
    int nrest = 0, given = 0;
    for (int i = 0; i < argc && nrest < 64; i++) {
        if (!strcmp(argv[i], "--app") && i + 1 < argc) { app = argv[++i]; continue; }
        if (!strcmp(argv[i], "--for")) given = 1;
        rest[nrest++] = argv[i];
    }
    args_t a;
    int rc = parse_args("allow-capture", nrest, rest, &a, 0);
    if (rc) return rc;
    if (a.target || !a.agent || !app || !*app) {
        fprintf(stderr, "usage: kai allow-capture --app <name> --agent claude|codex|cursor [--for 15m]\n"
                        "  <name> is the app Kai's message names: the app controlled (Safari, Terminal) or the "
                        "program that captures (screencapture, ffmpeg).\n");
        return 2;
    }
    if (!given) a.secs = 900;
    int terminal = kai_capture_app_is_terminal(app);
    if (terminal && a.secs > KAI_TERMINAL_ALLOW_MAX) {
        fprintf(stderr, "kai allow-capture: %s is allowed for at most 15 minutes: an agent controlling it can run "
                        "anything outside Kai's checks.\n", app);
        return 2;
    }
    if (a.secs > 86400) { fprintf(stderr, "kai allow-capture: --for is at most 1d for screen and app control.\n"); return 2; }
    const char *no = agent_supports("capture", 0, a.agent);
    if (no) { fprintf(stderr, "kai allow-capture: %s.\n", no); return 2; }
    if ((rc = gatekeep("allow-capture"))) return rc;   /* one writer: with the app, the app keeps these */
    if (terminal) {
        char why[200];
        snprintf(why, sizeof why, "Allow %s to control %s for 15 minutes (commands it runs there aren't checked by Kai).",
                 agent_title(a.agent), app);
        if (!owner_auth(why)) {
            fprintf(stderr, "kai allow-capture: owner authentication failed or there was no terminal to ask in. "
                            "Nothing was allowed.\n");
            return 5;
        }
    }
    long long until = (long long)time(NULL) + a.secs;
    if (kai_cli_grant_add(1, "capture", a.agent, app, NULL, until, NULL, NULL, 0) != 0) {
        fprintf(stderr, "kai allow-capture: couldn't save the grant\n"); return 1;
    }
    char what[400];
    snprintf(what, sizeof what, "Allowed %s to use or control %s%s (screen and app control), only through the commands "
             "and tools Kai checks; other apps still need their own. macOS still asks for its own permission",
             agent_title(a.agent), app, terminal ? " (commands it runs there aren't checked by Kai)" : "");
    return finish("allow-capture", what, until);
}

int kai_cmd_allow(int argc, char **argv) {
    (void)argc; (void)argv;
    fprintf(stderr, "Say exactly what to allow:\n"
                    "  kai allow-file <path> --read|--write --agent A [--for 1h]\n"
                    "  kai allow-fetch <domain> --agent claude [--for 1h]\n"
                    "  kai allow-mcp <server> [<tool>] --agent A [--for 1h]\n"
                    "  kai allow-upload <file> --to <host> --agent A [--for 1h]\n"
                    "  kai allow-capture --app <name> --agent A [--for 15m]\n");
    return 2;
}

int kai_cmd_block(int argc, char **argv) {
    args_t a;
    int rc = parse_args("block", argc, argv, &a, 0);
    if (rc) return rc;
    if (!a.target) { fprintf(stderr, "usage: kai block <host> [--agent claude|codex|cursor]\n"); return 2; }
    if ((rc = gatekeep("block"))) return rc;
    const char *agent = a.agent ? a.agent : "*";
    if (kai_cli_grant_add(0, "reach", agent, a.target, NULL, 0, NULL, NULL, 0) != 0) {
        fprintf(stderr, "kai block: couldn't save the rule\n"); return 1;
    }
    char d[400];
    snprintf(d, sizeof d, "kai block %s for %s", a.target, agent);
    kai_audit("kai", "block", "note", "terminal_rule", d);
    printf("Kai now stops %s's checked actions that reach %s (and its subdomains): shell commands that name it "
           "and web fetches. Until you remove it.\nUndo: kai undo · See all: kai rules\n%s\n",
           agent_title(agent), a.target, LIMIT_LINE);
    return 0;
}

int kai_cmd_undo(int argc, char **argv) {
    (void)argc; (void)argv;
    int g = gatekeep("undo");
    if (g) return g;
    if (kai_agent_rule_undo() != 0) { printf("Nothing to undo.\n%s\n", LIMIT_LINE); return 1; }
    kai_audit("kai", "undo", "note", "terminal_rule", "kai undo: last rule change reversed");
    printf("Undone: the rules are back to before your last change. See them: kai rules\n%s\n", LIMIT_LINE);
    return 0;
}

int kai_cmd_rules(int argc, char **argv) {
    (void)argc; (void)argv;
    cJSON *a = load_rules();
    long long now = (long long)time(NULL);
    int shown = 0;
    printf("What each agent may do beyond your policy (kai allow-… / kai block)\n");
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        if (!live(r, now)) continue;
        const char *op = jstr(r, "op"), *t = jstr(r, "target"), *to = jstr(r, "to");
        char shown_t[PATH_MAX], when[32] = "until removed";
        shorten(t, shown_t, sizeof shown_t);
        if (jnum(r, "until") > 0) when_str((long long)jnum(r, "until"), when, sizeof when);
        const char *who = agent_title(jstr(r, "agent"));
        if (!strcmp(jstr(r, "kind"), "block"))
            printf("  stops   %-12s reaching %s (and subdomains)\n", who, t);
        else if (!strcmp(op, "mcp"))
            printf("  allows  %-12s MCP %s · %s, %s\n", who, t, *to ? to : "every tool", when);
        else if (!strcmp(op, "upload"))
            printf("  allows  %-12s to send %s to %s, %s\n", who, shown_t, to, when);
        else if (!strcmp(op, "fetch"))
            printf("  allows  %-12s to fetch from %s, %s\n", who, t, when);
        else if (!strcmp(op, "capture"))
            printf("  allows  %-12s screen and app control: %s, %s\n", who, t, when);
        else
            printf("  allows  %-12s to %s %s (file tool), %s\n", who, op, shown_t, when);
        shown++;
    }
    if (!shown) printf("  nothing. Everything follows your policy (kai policy show).\n");
    printf("%s\n", LIMIT_LINE);
    cJSON_Delete(a);
    return 0;
}
