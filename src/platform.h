/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
/* Kai's platform layer: what differs between macOS/Linux (platform_posix.c)
 * and Windows (platform_win.c). The engine calls these and never tests for an
 * OS itself. Plain POSIX spelling differences (strcasecmp, opendir, flock...)
 * are mapped by compat/win/ on Windows instead. See docs/windows/PORTING.md. */
#ifndef KAI_PLATFORM_H
#define KAI_PLATFORM_H

#include <stddef.h>

/* Once, first thing in main(): Windows sets binary stdin/stdout (a hook's
 * JSON is read byte for byte: no CRLF folding, no ^Z end-of-file) and a UTF-8
 * console. POSIX: nothing. */
void kai_plat_init(void);

/* The user's home: $HOME, or %USERPROFILE% on Windows ('/'-separated). */
const char *kai_plat_home(void);

/* 1 on Windows: protected-path matching ignores letter case everywhere
 * (it already did for macOS). */
int kai_plat_is_windows(void);

/* Length of the root of an absolute path: "/" (1) on POSIX; "C:/" (3) or
 * "//server/share/" on Windows. 0 = relative. Expects kai_plat_absolute's
 * output form. */
size_t kai_plat_root_len(const char *p);
int kai_plat_path_is_abs(const char *p);

/* Path as written -> absolute, not yet normalized ('.'/'..' kept). Expands
 * ~ and $HOME; on Windows also %USERPROFILE%, %APPDATA%, %LOCALAPPDATA%,
 * $env:NAME, '\' -> '/', the \\?\ and \\.\ prefixes, UNC, drive-relative
 * (C:foo) and rooted (\foo) forms. Relative paths join cwd (or the process
 * cwd when cwd is NULL/empty). Caller frees. */
char *kai_plat_absolute(const char *path, const char *cwd);

/* Clean one path component in place, as the OS would open it. Windows: drop
 * an alternate data stream (".env::$DATA", "id:stream") and trailing dots and
 * spaces (".env." opens ".env"). POSIX: nothing. */
void kai_plat_fix_component(char *comp);

/* Expand environment references in a policy entry or a command word, in the
 * platform's syntax(es). POSIX: only what kai_expand_home does. Windows:
 * %NAME% and $env:NAME. Caller frees; NULL = nothing to expand. */
char *kai_plat_expand_env(const char *s);

/* Run a hook command with `input` on stdin, collecting stdout (stderr is
 * dropped), for at most timeout_ms, the way the agent runs it. shell=1: a
 * shell command (POSIX: /bin/sh -c; Windows: PowerShell, as Codex and Cursor
 * run hooks). shell=0: a program and its arguments, already quoted with
 * kai_plat_quote_argv (Windows: CreateProcessW, no shell, as Claude Code runs
 * an exec-form hook). Returns the exit status, -1 on timeout or failure. */
int kai_plat_run(const char *cmdline, int shell, const char *input, size_t inlen, char *out, size_t outlen,
                 size_t *outgot, int timeout_ms);

/* Windows: the 8.3 short form of an existing path ('/'-separated), when the
 * volume has short names. POSIX: a copy. 0 on success. */
int kai_plat_short_path(const char *path, char *out, size_t n);

/* Run argv[0] (searched on PATH) in cwd with stdin from the null device,
 * capturing stdout+stderr, killed after timeout_s. Returns the exit status,
 * or -1 (couldn't run / timed out). */
int kai_plat_run_argv(char *const argv[], const char *cwd, int timeout_s, char *out, size_t n);

/* Windows: argv as one command line, quoted for the MSVC CRT. Caller frees. */
char *kai_plat_quote_argv(char *const argv[]);

/* Is process `pid` alive? */
int kai_plat_pid_alive(int pid);

/* Monotonic milliseconds. */
long long kai_plat_now_ms(void);

/* Can someone other than the current user (or SYSTEM / Administrators)
 * change `path`? 1 = yes, with who in `who`; 0 = no; -1 = can't tell.
 * POSIX: group/other write bits. Windows: the file's DACL. */
int kai_plat_others_can_write(const char *path, char *who, size_t n);

/* Open a URL or settings page in the user's desktop (macOS `open`); 0 = done. */
int kai_plat_open_url(const char *url);

/* When `path` was created (sec, nsec): macOS birth time, Linux statx btime,
 * else ctime (stricter: an edit also counts); Windows creation time. */
struct stat;
void kai_plat_file_birth(const char *path, const struct stat *st, long long *sec, long long *nsec);
/* Modification time in nanoseconds. */
long long kai_plat_mtime_ns(const struct stat *st);

/* This program's own path ('/'-separated on Windows); 0 on success. */
int kai_plat_exe_path(char *buf, size_t n);

#endif
