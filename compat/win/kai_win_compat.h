/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Windows (MSVC) only: force-included into every translation unit by CMake
 * (/FI). It pulls in the CRT headers first, then maps the small POSIX surface
 * Kai's engine uses onto the CRT or onto src/platform_win.c, so the engine
 * keeps its POSIX spelling and carries no #ifdef _WIN32.
 *
 * Paths: Kai keeps paths '/'-separated internally ("C:/Users/a/.ssh/id").
 * Windows APIs accept '/', and the narrow (A) APIs take UTF-8 because kai.exe
 * declares the UTF-8 active code page in its manifest (compat/win/kai.manifest). */
#ifndef KAI_WIN_COMPAT_H
#define KAI_WIN_COMPAT_H
#ifdef _WIN32

#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef _CRT_NONSTDC_NO_WARNINGS
#define _CRT_NONSTDC_NO_WARNINGS
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

/* CRT headers first: the macros below must not rewrite their declarations. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <direct.h>
#include <process.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/utime.h>
#include <signal.h>
#include <limits.h>
#include <malloc.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef intptr_t ssize_t;
typedef int pid_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned short mode_t;

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#ifndef NAME_MAX
#define NAME_MAX 255
#endif

/* ---- files ---- */
#define O_NOFOLLOW 0
#define O_CLOEXEC 0
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif
#define O_DIRECTORY 0
int kai_win_open(const char *path, int flags, ...);
#define open kai_win_open

/* 64-bit sizes and times; "struct stat" and stat() both become _stat64. */
#define stat _stat64
#define fstat _fstat64
int kai_win_lstat(const char *path, struct _stat64 *st);
#define lstat kai_win_lstat
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#define S_ISLNK(m) 0
#define S_IRWXU 0700
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXG 0070
#define S_IRGRP 0040
#define S_IWGRP 0020
#define S_IXGRP 0010
#define S_IRWXO 0007
#define S_IROTH 0004
#define S_IWOTH 0002
#define S_IXOTH 0001

int kai_win_mkdir(const char *path);
#define mkdir(p, m) kai_win_mkdir(p)
int kai_win_rename(const char *from, const char *to);  /* replaces the target, like POSIX */
#define rename kai_win_rename
int kai_win_unlink(const char *path);                  /* clears read-only first */
#define unlink kai_win_unlink
/* Permission bits are not Windows' access model: chmod only toggles the
 * read-only attribute; ownership is checked by ACL (kai_plat_policy_acl_ok). */
int kai_win_chmod(const char *path, int mode);
#define chmod kai_win_chmod
#define fchmod(fd, m) 0
#define chown(p, u, g) 0
#define fchown(fd, u, g) 0
int kai_win_futimes(int fd, const void *tv);
#define futimes kai_win_futimes
int kai_win_symlink(const char *target, const char *path);
#define symlink kai_win_symlink
ssize_t kai_win_readlink(const char *path, char *buf, size_t n);
#define readlink kai_win_readlink
char *kai_win_realpath(const char *path, char *resolved);
#define realpath kai_win_realpath
char *kai_win_mkdtemp(char *tmpl);
#define mkdtemp kai_win_mkdtemp
int kai_win_mkstemp(char *tmpl);
#define mkstemp kai_win_mkstemp

#define popen _popen
#define pclose _pclose

ssize_t kai_win_pread(int fd, void *buf, size_t n, long long off);
#define pread kai_win_pread
int kai_win_dprintf(int fd, const char *fmt, ...);
#define dprintf kai_win_dprintf

/* ---- strings ---- */
#define strcasecmp _stricmp
#define strncasecmp _strnicmp
#define strtok_r strtok_s
char *kai_win_strcasestr(const char *h, const char *n);
#define strcasestr kai_win_strcasestr
int kai_win_asprintf(char **out, const char *fmt, ...);
#define asprintf kai_win_asprintf
char *kai_win_strndup(const char *s, size_t n);
#define strndup kai_win_strndup

/* ---- time ---- */
#define gmtime_r(t, tm) (gmtime_s((tm), (t)) == 0 ? (tm) : NULL)
#define localtime_r(t, tm) (localtime_s((tm), (t)) == 0 ? (tm) : NULL)
#define timegm _mkgmtime
char *kai_win_strptime(const char *s, const char *fmt, struct tm *tm);
#define strptime kai_win_strptime
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif
int kai_win_clock_gettime(int clk, struct timespec *ts);
#define clock_gettime kai_win_clock_gettime

/* ---- process ---- */
int kai_win_getppid(void);
#define getppid kai_win_getppid
#define getuid() 0u
#define geteuid() 0u
#define getgid() 0u
uint32_t kai_win_random(void);
#define arc4random kai_win_random
/* kill(pid, 0): is it alive; any other signal terminates it. */
int kai_win_kill(int pid, int sig);
#define kill kai_win_kill
#ifndef SIGKILL
#define SIGKILL 9
#endif
#ifndef SIGPIPE
#define SIGPIPE 13
#endif
#ifndef SIGHUP
#define SIGHUP 1
#endif
#ifndef SIGALRM
#define SIGALRM 14
#endif

#ifdef __cplusplus
}
#endif

#endif /* _WIN32 */
#endif
