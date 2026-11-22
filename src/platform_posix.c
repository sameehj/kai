/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Platform layer, macOS and Linux. See platform.h. */
#include "platform.h"
#include "internal.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <fcntl.h>
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

extern char **environ;

void kai_plat_init(void) {}

const char *kai_plat_home(void) {
    const char *h = getenv("HOME");
    return (h && *h) ? h : "/";
}

int kai_plat_is_windows(void) { return 0; }

size_t kai_plat_root_len(const char *p) { return (p && p[0] == '/') ? 1 : 0; }
int kai_plat_path_is_abs(const char *p) { return kai_plat_root_len(p) > 0; }

char *kai_plat_absolute(const char *path, const char *cwd) {
    char *exp = kai_expand_home(path);
    if (!exp || exp[0] == '/') return exp;
    sb_t raw;
    sb_init(&raw);
    if (cwd && *cwd) sb_adds(&raw, cwd);
    else {
        char buf[PATH_MAX];
        if (getcwd(buf, sizeof buf)) sb_adds(&raw, buf);
    }
    sb_adds(&raw, "/");
    sb_adds(&raw, exp);
    free(exp);
    return sb_take(&raw);
}

void kai_plat_fix_component(char *comp) { (void)comp; }

char *kai_plat_expand_env(const char *s) { (void)s; return NULL; }

/* Run cmd with /bin/sh, input on stdin; collect stdout. */
int kai_plat_run(const char *cmd, const char *input, size_t inlen, char *out, size_t outlen,
                 size_t *outgot, int timeout_ms) {
    if (outlen) out[0] = '\0';
    if (outgot) *outgot = 0;
    int in[2], o[2];
    if (pipe(in) != 0) return -1;
    if (pipe(o) != 0) { close(in[0]); close(in[1]); return -1; }
    pid_t pid = fork();
    if (pid < 0) { close(in[0]); close(in[1]); close(o[0]); close(o[1]); return -1; }
    if (pid == 0) {
        dup2(in[0], 0);
        dup2(o[1], 1);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, 2);
        close(in[0]); close(in[1]); close(o[0]); close(o[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(in[0]);
    close(o[1]);
    signal(SIGPIPE, SIG_IGN);
    ssize_t w = write(in[1], input, inlen);
    (void)w;
    close(in[1]);
    size_t got = 0;
    long long t0 = kai_plat_now_ms();
    for (;;) {
        long left = (long)(timeout_ms - (kai_plat_now_ms() - t0));
        if (left <= 0) break;
        struct pollfd pf = {o[0], POLLIN, 0};
        int r = poll(&pf, 1, (int)left);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        char buf[1024];
        ssize_t n = read(o[0], buf, sizeof buf);
        if (n <= 0) break;
        if (got + 1 < outlen) {
            size_t take = (size_t)n < outlen - 1 - got ? (size_t)n : outlen - 1 - got;
            memcpy(out + got, buf, take);
            got += take;
            out[got] = '\0';
        }
    }
    close(o[0]);
    if (outgot) *outgot = got;
    int status = 0;
    for (int i = 0; i < 50; i++) { /* give it up to 0.5 s to exit after closing stdout */
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        usleep(10000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return -1;
}

/* Run argv in cwd with stdin from /dev/null, capturing stdout+stderr, killed
 * after timeout_s. Returns the exit status, or -1 (couldn't run / timed out). */
int kai_plat_run_argv(char *const argv[], const char *cwd, int timeout_s, char *out, size_t n) {
    if (n) out[0] = '\0';
    int p[2];
    if (pipe(p) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return -1; }
    if (pid == 0) {
        if (cwd && chdir(cwd) != 0) _exit(127);
        int dn = open("/dev/null", O_RDONLY);
        if (dn >= 0) { dup2(dn, 0); close(dn); }
        dup2(p[1], 1); dup2(p[1], 2);
        close(p[0]); close(p[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(p[1]);
    size_t got = 0;
    time_t end = time(NULL) + timeout_s;
    int timed_out = 0;
    for (;;) {
        int left = (int)(end - time(NULL));
        if (left <= 0) { timed_out = 1; break; }
        struct pollfd pf = {p[0], POLLIN, 0};
        int r = poll(&pf, 1, left * 1000);
        if (r <= 0) { if (r == 0) timed_out = 1; if (r < 0 && errno == EINTR) continue; break; }
        char buf[4096];
        ssize_t k = read(p[0], buf, sizeof buf);
        if (k <= 0) break;
        if (n && got < n - 1) {
            size_t c = (size_t)k < n - 1 - got ? (size_t)k : n - 1 - got;
            memcpy(out + got, buf, c); got += c; out[got] = '\0';
        }
    }
    close(p[0]);
    int st = 0;
    if (timed_out) { kill(pid, SIGTERM); sleep(1); kill(pid, SIGKILL); waitpid(pid, &st, 0); return -1; }
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int kai_plat_pid_alive(int pid) { return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM); }

long long kai_plat_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int kai_plat_others_can_write(const char *path, char *who, size_t n) {
    struct stat st;
    if (who && n) who[0] = '\0';
    if (stat(path, &st) != 0) return -1;
    if (st.st_mode & S_IWOTH) { if (who) kai_strlcpy(who, "everyone", n); return 1; }
    if (st.st_mode & S_IWGRP) { if (who) kai_strlcpy(who, "its group", n); return 1; }
    return 0;
}

int kai_plat_open_url(const char *url) {
#ifdef __APPLE__
    pid_t pid;
    char *av[] = {"/usr/bin/open", (char *)url, NULL};
    if (posix_spawn(&pid, "/usr/bin/open", NULL, NULL, av, environ) != 0) return -1;
    waitpid(pid, NULL, 0);
    return 0;
#else
    (void)url;
    return -1;
#endif
}

int kai_plat_exe_path(char *buf, size_t n) {
    ssize_t r = readlink("/proc/self/exe", buf, n - 1);
    if (r <= 0) return -1;
    buf[r] = 0;
    return 0;
}

/* When this file was created: device + inode alone don't identify a file,
 * since a freed inode number can come straight back for a new file (ext4 does
 * at once; on macOS, HFS+, exFAT, FAT and network volumes can; APFS numbers
 * rarely). macOS: st_birthtimespec. Linux: statx btime. Neither: ctime, which
 * is stricter (an edit also ends the grant). */
void kai_plat_file_birth(const char *path, const struct stat *st, long long *sec, long long *nsec) {
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

long long kai_plat_mtime_ns(const struct stat *st) {
#ifdef __APPLE__
    return (long long)st->st_mtimespec.tv_sec * 1000000000LL + st->st_mtimespec.tv_nsec;
#else
    return (long long)st->st_mtim.tv_sec * 1000000000LL + st->st_mtim.tv_nsec;
#endif
}

char *kai_plat_quote_argv(char *const argv[]) {
    sb_t b;
    sb_init(&b);
    for (int i = 0; argv[i]; i++) {
        if (i) sb_adds(&b, " ");
        sb_adds(&b, "'");
        for (const char *c = argv[i]; *c; c++) {
            if (*c == '\'') sb_adds(&b, "'\\''");
            else sb_add(&b, c, 1);
        }
        sb_adds(&b, "'");
    }
    return sb_take(&b);
}
