# Porting Kai's C core to Windows

Phase 1 of the Windows port: the C core in `src/` (policy engine, detectors,
redaction, audit log, the `kai` CLI and the agent hooks) built natively with
MSVC on Windows 10/11. The SwiftUI app (`app/macos`), the network extension and
the Endpoint Security storage extension are macOS-only and out of scope.

This file was written before any code changed (the baseline), then extended
with the design that came out of it.

## 1. Baseline: what in `src/` is POSIX-only

Counts are call sites per file at `master` 4c6ac84.

| File | POSIX / macOS-only calls | Windows answer |
|---|---|---|
| util.c | `_NSGetExecutablePath`, `readlink("/proc/self/exe")`, `realpath`, `getcwd`, `getenv("HOME")`, paths assumed to start with `/` | platform layer: exe path, home dir, canonical path |
| audit.c | `flock`(3), `fchmod`(2), `futimes`, `chown`, `geteuid`, `gmtime_r`/`localtime_r`, `mkdir(p, 0700)` | shims (`flock` -> `LockFileEx`; chmod/chown are no-ops, ACLs are checked by `kai status`) |
| policy.c | `fnmatch`(6), `regcomp`, `rename`, `chmod`, `strcasecmp` | `fnmatch` shim; musl regex (vendored); `rename` -> `MoveFileExW(REPLACE_EXISTING)` |
| scan.c | `regexec`(3), `realpath`, `getpwuid`, `getcwd`, `strncasecmp`(17), '/'-only path parsing | musl regex; `realpath` shim on `GetFinalPathNameByHandleW`; Windows path forms canonicalized before matching (section 3) |
| shell.c | bash-only tokenizer (backslash = escape) | new `winshell.c`: cmd.exe and PowerShell readers next to it (section 5) |
| hooks.c | `opendir`/`readdir`(3), `mkdir`(7), `rename`, `strptime`/`timegm`, `getpid` | shims |
| install.c | `lstat`, `S_ISDIR`, `rename`, `fsync`, `access`, `rmdir`, POSIX hook command strings | shims; Windows agent config paths and quoting (section 4) |
| manage.c | `posix_spawn` + `waitpid`, `isatty`, `fsync` | platform spawn (`CreateProcessW`) |
| health.c | `fork`+`execl`+`pipe`+`dup2`+`poll`+`kill`+`waitpid` (runs a hook probe with a timeout), `getpwuid(st_uid)` (owner check), `clock_gettime`, `usleep` | platform `kai_plat_run` (pipes + timeout on `CreateProcessW`); owner check -> ACL check |
| demo.c | `fork`/`execvp`/`pipe`/`poll`/`mkdtemp`/`kill` (`kai demo --live`) | platform spawn; `mkdtemp` shim |
| session.c | `proc_pidinfo` (libproc), `flock`, `kill(pid, 0)`, `rename`(6), `chmod`(4) | platform process info (`OpenProcess`, Toolhelp32) |
| proc.c | libproc / `sysctl(KERN_PROCARGS2)` / `/proc`, code-signing Team ID (Security.framework) | platform process info: `QueryFullProcessImageNameW`, Toolhelp32 parent pid, command line via `NtQueryInformationProcess(ProcessCommandLineInformation)`; no Team ID (Authenticode is a later phase) |
| agent_rules.c | `readpassphrase`, `dlopen`/`dlsym` (macOS LocalAuthentication), `getpwuid`, `realpath`, `fnmatch` | Touch ID path is `__APPLE__` already; `readpassphrase` -> console read with echo off |
| approval_store.c | `pthread_rwlock_*`, `pthread_mutex_*`, `stdatomic` | `SRWLOCK` shim (single-process use; the CLI is single-threaded) |
| activity.c, grant.c, grant_cli.c, report.c, stats.c, status.c | `opendir`/`readdir`, `localtime_r`/`gmtime_r`, `strptime`/`timegm`, `popen` (status) | shims; `popen` -> `_popen` |
| gateway.c | BSD sockets, `pthread_create`, `signal(SIGPIPE)`, libcurl | **not built on Windows**: `kai gateway` (the Internet wall's MCP gateway) is out of scope; `gateway_none.c` says so |
| storaged.c | `popen`/`getline` driving the Endpoint Security extension | **not built on Windows**: `storaged_none.c` (no Files wall on Windows) |
| storage.c, storage_prof.c | `FWRITE` kernel flag, `stdatomic` | builds as is (pure decision code) |
| net.c | `strcasecmp` | shim |

Headers used that MSVC does not have: `unistd.h` (20 files), `dirent.h` (8),
`strings.h` (7), `fnmatch.h` (3), `sys/file.h` (2), `sys/wait.h` (3),
`pwd.h` (2), `poll.h` (2), `pthread.h` (2), `spawn.h`, `regex.h`,
`readpassphrase.h`, `libproc.h`, `sys/socket.h`, `arpa/inet.h`, `curl/curl.h`.

Paths with `/` hard-coded: every protected-path check assumes an absolute path
starts with `/` and splits on `/` (`kai_normalize_path`, `path_matches`,
`under_root`, `kai_path_is_kai_program`, the AGENT_CONTROL suffixes such as
`/.claude/settings.json`). Home is `$HOME`; Kai's home is `~/.kai`.

Signals: `SIGPIPE` is ignored in gateway.c (not built); `kill(pid, 0)` is used
as "is this process alive" (session.c, health.c); `kill(pid, SIGKILL)` ends a
probe that timed out. `/dev/null` and `/dev/tty` appear in health.c and
demo.c.

## 2. Design: the platform layer

Two pieces, both only compiled on Windows; the macOS/Linux build and the
Makefile are unchanged except for the new portable files.

1. **`compat/win/` - POSIX shim headers** (`unistd.h`, `dirent.h`,
   `strings.h`, `fnmatch.h`, `sys/file.h`, `sys/time.h`, `pwd.h`, `regex.h`,
   ...) put first on the include path by CMake on Windows only. They declare
   the small POSIX surface the engine uses and map it to the CRT or to
   functions in `src/platform_win.c`. The engine files keep their POSIX
   spelling and gain no `#ifdef _WIN32`.
2. **`src/platform.h`** - the things that are *different*, not just spelled
   differently, with `platform_posix.c` and `platform_win.c`:
   - `kai_plat_home()`: `$HOME`, or `%USERPROFILE%` on Windows.
   - `kai_plat_canonical(path, cwd)`: the canonical form every protected-path
     match uses (section 3).
   - `kai_plat_path_is_abs()`, `kai_plat_exe_path()`.
   - `kai_plat_run()`: run a program with stdin text, capture stdout, with a
     timeout (health probes, `kai demo`, `kai policy` approvals).
   - `kai_plat_pid_alive()`, process info for `proc.c`.
   - `kai_plat_policy_acl_ok()`: is the policy file writable by other users?

Where an existing file already had `#ifdef __APPLE__ ... #else` (Linux), the
Windows code goes into the platform layer, not a third branch.

## 3. Paths on Windows: one canonical form

Internally Kai keeps paths as `/`-separated strings (`C:/Users/Ann/.ssh/id`).
Windows APIs accept `/`, so files open as they are, and the engine's
`/`-based matching keeps working. Before every protected-path match a path is
canonicalized:

1. Expand `~`, `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`, `%HOMEDRIVE%%HOMEPATH%`,
   `$env:USERPROFILE` (and the other `$env:` names), `$HOME`.
2. `\` -> `/`. Strip `\\?\` and `\\.\`; `\\?\UNC\srv\share` -> `//srv/share`.
3. Make absolute: drive-relative (`C:foo`) and rooted (`\foo`) forms use the
   cwd's drive.
4. Per component: drop an alternate data stream (`.env::$DATA`,
   `id_ed25519:stream` -> base name), strip trailing dots and spaces
   (`.env.` and `.env ` open `.env`), collapse `.` and `..`.
5. If the path (or its deepest existing parent) exists, resolve it with
   `GetFinalPathNameByHandleW`: symlinks, junctions, mount points and 8.3 short
   names (`SAMEEH~1`) come back as the real long path in its on-disk case. The
   non-existing tail is appended.
6. Drive letter upper case. All comparisons ignore case (they already did for
   macOS, G4).

The lexical form (steps 1-4) and the resolved form (step 5) are both checked,
as the existing code already does with `realpath` (`resolved_variant`).

## 4. Settings location

See `docs/windows/README.md`. Phase 1 keeps everything in `%USERPROFILE%\.kai`
(policy, keys, grants, logs): one folder, matching macOS, so the existing
"Kai's own settings" protection covers all of it as one tree.

## 5. Windows shells

The bash reader (`shell.c`) treats `\` as an escape, so `type C:\Users\a\.env`
would reach the checks as `C:Usersa.env`. Windows commands are read by
`winshell.c`, which knows cmd.exe (`^` escapes, `&`, `&&`, `||`, `|`,
`%VAR%`, `cmd /c`) and PowerShell (quotes, backtick escapes, `;`, `|`,
aliases, `$env:VAR`, `-EncodedCommand` base64 UTF-16LE decoding,
`iex (iwr ...)`). Which reader runs depends on the agent's tool (section in
README: Claude Code's Bash tool is Git Bash, its PowerShell tool and Codex/Cursor
use PowerShell); when it isn't known, every reader runs and any hit stops the
command.
