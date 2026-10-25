/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Who is this process? Reads a process's executable, arguments, parent and
 * (on macOS) code-signing Team ID, and decides whether it is an agent or runs
 * under one. The network extension uses this to apply the egress wall only to
 * agent process trees; everything else on the machine is left alone.
 */
#include "internal.h"

#include <fnmatch.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <libproc.h>
#include <sys/sysctl.h>
#else
#include <stdio.h>
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

#else /* Linux */

int kai_proc_read(int pid, kai_proc *out) {
    memset(out, 0, sizeof *out);
    out->pid = pid;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    size_t n;
    char *stat = kai_read_file(path, 65536, &n);
    if (!stat) return -1;
    /* comm may contain spaces and ')': ppid follows the last ") X " */
    char *rp = strrchr(stat, ')');
    int ppid = 0;
    if (!rp || sscanf(rp + 1, " %*c %d", &ppid) != 1) { free(stat); return -1; }
    free(stat);
    out->ppid = ppid;
    snprintf(path, sizeof path, "/proc/%d/exe", pid);
    ssize_t l = readlink(path, out->exe, sizeof out->exe - 1);
    out->exe[l > 0 ? l : 0] = '\0';
    snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
    char *cl = kai_read_file(path, 1 << 20, &n);
    if (cl) {
        for (size_t i = 0; i < n;) {
            size_t len = strnlen(cl + i, n - i);
            push_arg(out, cl + i, len);
            i += len + 1;
        }
        free(cl);
    }
    return 0;
}
int kai_proc_read_fast(int pid, kai_proc *out) { return kai_proc_read(pid, out); }

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

/* ---- storage-wall-free session discovery (S-redesign item 1) ---- */
#ifdef __APPLE__
/* Session scan (perf-tuned): ONE fast pass over all processes (no per-process
 * code-signing lookup -- kai_proc_read_fast skips it), building an in-memory
 * table (pid, parent index, is-agent, exe). Agent roots and their child counts
 * are then found with in-memory ancestry walks -- no extra syscalls, no O(n^2)
 * re-reads. The earlier version did a SecCode verification per process and an
 * O(n^2) syscall child count, which made the machine slow when polled. */
static const struct { const char *mark, *name; } HOST_APPS[] = {
    {"/Terminal.app/", "Terminal"}, {"/iTerm.app/", "iTerm"},
    {"/Cursor.app/", "Cursor"}, {"/Visual Studio Code.app/", "VS Code"},
    {"/WezTerm.app/", "WezTerm"}, {"/Alacritty.app/", "Alacritty"},
    {"/kitty.app/", "kitty"}, {"/Warp.app/", "Warp"}, {"/Ghostty.app/", "Ghostty"},
};

typedef struct { int pid, parent; int is_agent; char name[64]; char exe[1024]; } scan_ent;

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
    /* One pass: read each process ONCE (fast: no code-signing), classify it. */
    for (int i = 0; i < np; i++) {
        int pid = pids[i];
        if (pid <= 1) continue;
        kai_proc pr;
        if (kai_proc_read_fast(pid, &pr) != 0) continue;
        tab[nt].pid = pid;
        tab[nt].parent = pr.ppid;                 /* resolved to an index below */
        kai_strlcpy(tab[nt].exe, pr.exe, sizeof tab[nt].exe);
        /* Agents are matched by exe/arg (team omitted: the walls still use team;
         * the display scan doesn't pay the code-signing cost). */
        tab[nt].is_agent = kai_agent_match(p, pr.exe, (const char *const *)pr.argv,
                                           pr.argc, "", tab[nt].name, sizeof tab[nt].name);
        kai_proc_free(&pr);
        nt++;
    }
    free(pids);

    /* Resolve each entry's parent to a table index (one O(n^2) integer scan, no
     * syscalls), so ancestry walks below are O(depth). */
    for (int i = 0; i < nt; i++) {
        int ppid = tab[i].parent, idx = -1;
        for (int j = 0; j < nt; j++) if (tab[j].pid == ppid) { idx = j; break; }
        tab[i].parent = idx;
    }

    kai_session *arr = NULL; int count = 0, cap = 0;
    for (int i = 0; i < nt; i++) {
        if (!tab[i].is_agent) continue;
        /* Root = topmost process of this agent: parent (if any) isn't the same agent. */
        int par = tab[i].parent;
        if (par >= 0 && tab[par].is_agent && strcmp(tab[par].name, tab[i].name) == 0) continue;

        kai_session s;
        memset(&s, 0, sizeof s);
        snprintf(s.id, sizeof s.id, "scan-%d", tab[i].pid);
        kai_strlcpy(s.agent, tab[i].name, sizeof s.agent);
        s.root_pid = tab[i].pid;
        s.source = KAI_SESS_SCAN;
        struct proc_bsdinfo bi;
        if (proc_pidinfo(tab[i].pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == (int)sizeof bi)
            s.started_utc = (long long)bi.pbi_start_tvsec;
        struct proc_vnodepathinfo vp;
        if (proc_pidinfo(tab[i].pid, PROC_PIDVNODEPATHINFO, 0, &vp, sizeof vp) > 0)
            kai_strlcpy(s.project, vp.pvi_cdir.vip_path, sizeof s.project);
        /* Host app: walk ancestors via the table (no syscalls). */
        for (int a = tab[i].parent, depth = 0; a >= 0 && depth < 40; a = tab[a].parent, depth++) {
            int found = 0;
            for (size_t k = 0; k < sizeof HOST_APPS / sizeof HOST_APPS[0]; k++)
                if (strstr(tab[a].exe, HOST_APPS[k].mark)) {
                    kai_strlcpy(s.host_app, HOST_APPS[k].name, sizeof s.host_app); found = 1; break;
                }
            if (found) break;
        }
        /* Child count: processes whose ancestry reaches this root (in-memory). */
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
int kai_sessions_scan(const kai_policy *p, kai_session **out, int *n) {
    (void)p; *out = NULL; *n = 0; return 0;
}
#endif
