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
