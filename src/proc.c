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

int kai_proc_read(int pid, kai_proc *out) {
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
    read_team(pid, out->team, sizeof out->team);
    return 0;
}

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
/* Walk up from `pid` to find the terminal/app hosting it. */
static void find_host_app(int pid, char *out, size_t n) {
    if (n) out[0] = '\0';
    static const struct { const char *mark, *name; } apps[] = {
        {"/Terminal.app/", "Terminal"}, {"/iTerm.app/", "iTerm"},
        {"/Cursor.app/", "Cursor"}, {"/Visual Studio Code.app/", "VS Code"},
        {"/WezTerm.app/", "WezTerm"}, {"/Alacritty.app/", "Alacritty"},
        {"/kitty.app/", "kitty"}, {"/Warp.app/", "Warp"}, {"/Ghostty.app/", "Ghostty"},
    };
    for (int depth = 0; pid > 1 && depth < 32; depth++) {
        kai_proc pr;
        if (kai_proc_read(pid, &pr) != 0) return;
        int parent = pr.ppid;
        for (size_t k = 0; k < sizeof apps / sizeof apps[0]; k++)
            if (strstr(pr.exe, apps[k].mark)) { kai_strlcpy(out, apps[k].name, n); kai_proc_free(&pr); return; }
        kai_proc_free(&pr);
        if (parent <= 1 || parent == pid) return;
        pid = parent;
    }
}

/* Is `pid` a descendant of `root` (root excluded)? Bounded ancestry walk. */
static int descends_from(int pid, int root) {
    for (int depth = 0; pid > 1 && depth < 64; depth++) {
        kai_proc pr;
        if (kai_proc_read(pid, &pr) != 0) return 0;
        int parent = pr.ppid;
        kai_proc_free(&pr);
        if (parent == root) return 1;
        if (parent <= 1 || parent == pid) return 0;
        pid = parent;
    }
    return 0;
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

    kai_session *arr = NULL; int count = 0, cap = 0;
    for (int i = 0; i < np; i++) {
        int pid = pids[i];
        if (pid <= 1) continue;
        kai_proc pr;
        if (kai_proc_read(pid, &pr) != 0) continue;
        char name[64];
        int is_agent = kai_agent_match(p, pr.exe, (const char *const *)pr.argv, pr.argc,
                                       pr.team, name, sizeof name);
        int ppid = pr.ppid;
        kai_proc_free(&pr);
        if (!is_agent) continue;
        /* Root = the topmost process of this agent: its parent is not the same agent. */
        int parent_same = 0;
        if (ppid > 1) {
            kai_proc pp;
            if (kai_proc_read(ppid, &pp) == 0) {
                char pname[64];
                if (kai_agent_match(p, pp.exe, (const char *const *)pp.argv, pp.argc,
                                    pp.team, pname, sizeof pname) && strcmp(pname, name) == 0)
                    parent_same = 1;
                kai_proc_free(&pp);
            }
        }
        if (parent_same) continue;

        kai_session s;
        memset(&s, 0, sizeof s);
        snprintf(s.id, sizeof s.id, "scan-%d", pid);     /* stable while the root lives */
        kai_strlcpy(s.agent, name, sizeof s.agent);
        s.root_pid = pid;
        s.source = KAI_SESS_SCAN;
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == (int)sizeof bi)
            s.started_utc = (long long)bi.pbi_start_tvsec;
        struct proc_vnodepathinfo vp;
        if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, sizeof vp) > 0)
            kai_strlcpy(s.project, vp.pvi_cdir.vip_path, sizeof s.project);
        find_host_app(ppid, s.host_app, sizeof s.host_app);
        for (int j = 0; j < np; j++)
            if (pids[j] > 1 && pids[j] != pid && descends_from(pids[j], pid)) s.child_count++;

        if (count == cap) {
            int nc = cap ? cap * 2 : 8;
            kai_session *na = realloc(arr, (size_t)nc * sizeof *na);
            if (!na) break;
            arr = na; cap = nc;
        }
        arr[count++] = s;
    }
    free(pids);
    *out = arr; *n = count;
    return count;
}
#else
int kai_sessions_scan(const kai_policy *p, kai_session **out, int *n) {
    (void)p; *out = NULL; *n = 0; return 0;
}
#endif
