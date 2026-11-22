# Kai on Windows (dev preview)

Kai's C core, the `kai` command and the agent hooks build and run natively on
Windows 10 and 11 (MSVC, no Cygwin, MSYS runtime or WSL). They stop Claude
Code, Codex and Cursor from reading secrets and running risky commands through
the same checks as on macOS.

**This is a developer preview: hooks only, no app.**

- **CLI only.** There is no Kai app on Windows: no menu bar, no Settings, no
  Activity window. `kai status`, `kai doctor`, `kai log show` and the policy
  file are the interface.
- **Hooks only.** There is no Internet wall and no Files wall on Windows yet.
  Nothing is enforced by Windows itself.
- **Hooks are a guardrail, not a sandbox.** They see the tool calls each agent
  reports to them. A script or program the agent writes and then runs can read
  any file you can read and connect anywhere: the hook only sees
  `python read.py` or `.\t.ps1`, not what it opens. So can a path or command
  built at run time (`$d = '.ss' + 'h'`). See the rows marked *gets through*
  in [../ESCAPES.md](../ESCAPES.md).
- **Unsigned development build.** Windows SmartScreen and some antivirus tools
  warn about an unsigned `kai.exe`. There is no installer, no signing and no
  release in this phase.

## Build

Needs Visual Studio 2022 Build Tools with the "Desktop development with C++"
workload, CMake 3.21 or later, and Python 3 for the tests.

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

`build\Release\kai.exe` uses the static C runtime: it needs no Visual C++
redistributable. Its manifest sets the UTF-8 code page and long-path support.
The tests are the shared C unit tests, the Windows unit tests
(`tests/windows/run_win_tests.c`), the escape suite and the Windows hook tests
(`tests/windows/run_win_hook_tests.py`).

A release build (`-DKAI_RELEASE=ON`) ignores `KAI_HOME` and `KAI_POLICY`, as on
macOS.

## Install

Hooks must point at an installed `kai.exe`, never a build folder. Install it
where Kai treats it as its own program (agents may run it but not delete or
change it):

```powershell
cmake --install build --config Release --prefix "$env:LOCALAPPDATA\Programs\Kai"
& "$env:LOCALAPPDATA\Programs\Kai\kai.exe" install all
& "$env:LOCALAPPDATA\Programs\Kai\kai.exe" doctor
```

`kai install all` adds Kai's hooks to every agent it finds; `kai uninstall all`
removes them; `kai doctor` runs each installed hook the way its agent runs it
and checks that it denies a test request.

`kai install` refuses a `kai.exe` that sits inside a git checkout (it walks up
the folders looking for `.git`). A machine with a repository at the root of a
drive (`C:\.git`) trips this for every path on that drive; a dev build can
override it with `KAI_TEST_ALLOW_DEV_HOOK=1`.

### Where Kai keeps its settings

| What | Where |
|---|---|
| Policy, keys, grants, audit log, activity | `%USERPROFILE%\.kai` |
| The program | `%LOCALAPPDATA%\Programs\Kai\kai.exe` |

Everything Kai keeps is in one folder, as on macOS, so the always-on "Kai's own
settings" protection covers all of it: no agent may read or change
`%USERPROFILE%\.kai` through its tools, or Kai's program, or any agent's hook
settings (`.claude\settings.json`, `.codex\hooks.json`, `.cursor\hooks.json`,
and Codex's and Claude Code's machine-wide files under `%ProgramData%` and
`Program Files`).

`kai status --json` reports `"state": "degraded"` when the policy file's access
list lets another account change it (`policy.others_can_write`,
`policy.writable_by`). Accounts that can change anything anyway (SYSTEM,
Administrators) and you don't count.

### Changing what Kai allows

There is no Settings window. Edit `%USERPROFILE%\.kai\policy` (`kai init`
writes the default one), then accept the change in **your own terminal**:

```powershell
notepad "$env:USERPROFILE\.kai\policy"
& "$env:LOCALAPPDATA\Programs\Kai\kai.exe" policy accept
```

Kai refuses `kai policy accept` from an agent's shell. Paths may use `%VAR%`,
`$env:VAR`, `~` and either slash; quote a path with spaces:
`protect "%LOCALAPPDATA%/Some App/User Data"`.

## How each agent runs Kai on Windows

What was measured on a real machine and what comes from the vendor's docs is
marked; see [TEST-RESULTS.md](TEST-RESULTS.md):

| Agent | Config Kai writes | How the agent starts the hook | What Kai writes |
|---|---|---|---|
| Claude Code | `%USERPROFILE%\.claude\settings.json` | An exec-form entry (`command` + `args`) is started directly, no shell (**measured**, 2.1.303). Shell-form commands run in Git Bash, or PowerShell without it (Claude Code docs). | Exec form: `"command": "C:/.../kai.exe", "args": ["hook", "claude"]`. No quoting can go wrong, spaces included. The `PowerShell` tool is in the matcher. |
| Codex | `%USERPROFILE%\.codex\hooks.json` (or `%CODEX_HOME%`) | `powershell.exe` (**measured**, codex-cli 0.149.1) | The program path bare when every shell reads it as one word, else its 8.3 short name (`C:/Users/FIRSTL~1/...`), else `& 'C:/.../kai.exe' hook codex` |
| Cursor | `%USERPROFILE%\.cursor\hooks.json` | PowerShell, or bash when Cursor finds Git Bash (Cursor forum reports; see TEST-RESULTS.md for the live run) | Same as Codex. Kai also strips the UTF-8 byte-order mark Cursor is reported to put on the event on Windows. |

**Codex: trust the hooks once.** Codex runs a new or changed hook only after
you review it: open Codex, run `/hooks`, and trust Kai's entries. Until then
`kai doctor` says "Codex hasn't run Kai's hooks yet". Every `kai install codex`
changes the entries' hash, so trust them again after reinstalling.

Kai writes no fail-closed setting (as on macOS), so a missing `kai.exe` is
expected not to block an agent: the hook fails to start and each agent's docs
say it then goes on. Unlike macOS there is no "Kai is missing" message in the
agent (the macOS sh wrapper prints it; Windows hooks run `kai.exe` directly).
`kai doctor` reports a missing program.

## What Kai checks on Windows

Everything the macOS hooks check (protected files, secrets in prompts and MCP
arguments, uploads, Kai's own settings, hook settings, credential printing),
plus:

**Windows paths.** Every path is canonicalized before it is matched:

- `\` and `/` are the same; letter case is ignored; drive letters, `\\?\`,
  `\\.\`, `\\?\UNC\...` and UNC paths (`\\server\share`) are understood, and
  this machine's admin shares (`\\localhost\C$\...`) are the drive itself.
- Trailing dots and spaces are dropped (`.env.` opens `.env`), and so are
  alternate data streams (`.env::$DATA`, `id_ed25519:stream`).
- Existing paths are resolved with `GetFinalPathNameByHandleW`: symlinks,
  junctions, mount points and 8.3 short names (`C:\Users\SAMEEH~1\.ssh`)
  become the real path.
- `~`, `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%` (any `%VAR%`),
  `$env:VAR` and Git Bash forms (`/c/Users/...`, `/cygdrive/c/...`) are expanded.

**Windows secret stores**, protected by default in addition to the shared list
(`~\.ssh`, `~\.aws`, `~\.kube`, `~\.docker\config.json`, `~\.npmrc`, `.env*`,
private keys...): `~\.azure`, `~\.git-credentials`, `%APPDATA%\gcloud`, the
global npmrc (`%APPDATA%\npm\etc\npmrc`), PowerShell's history
(`PSReadLine\ConsoleHost_history.txt`), the DPAPI and Credential Manager
folders (`%APPDATA%\Microsoft\Protect`, `...\Credentials`), and the Chrome,
Edge, Brave and Firefox profiles.

**PowerShell and cmd.exe commands.** `src/winshell.c` reads a command the way
PowerShell and cmd.exe would (quotes, `` ` `` and `^` escapes, `%VAR%` and
`$env:VAR`, `;` `|` `&` `&&` `||`, nested `powershell -Command`,
`-EncodedCommand` (decoded), `cmd /c`, `Start-Process`, `iex`), and hands the
shell checks the same work as bash: `Get-Content`/`gc`/`cat`/`type`/`more`/
`Select-String`/`findstr` are reads; `Copy-Item`/`copy`/`xcopy`/`robocopy` and
`certutil -encode` are copies; `Invoke-WebRequest`/`iwr`/`Invoke-RestMethod`/
`irm`/`curl.exe`/`Start-BitsTransfer`/`bitsadmin`/`certutil -urlcache` and
`Net.WebClient` calls are downloads and uploads; `iex (iwr ...)` and
`iwr ... | iex` run downloaded code. Kai's `reach` rules (`kai block <host>`)
apply to their URLs.

**Destructive commands (Windows only).** `Remove-Item -Recurse -Force` (and
`ri`/`rm`/`del`/`rd` with those parameters), `del /s /q`, `rd /s` / `rmdir /s`,
`format <drive>`, `diskpart`, `vssadmin`/`wmic` shadow-copy deletion,
`cipher /w`, `Format-Volume`, `Clear-Disk` and `Remove-Partition` are stopped.
Claude Code asks you; Codex and Cursor deny. Bash's `rm -rf` is not stopped,
on Windows or macOS (no destructive-command rule there yet).

Which shell a command is for isn't always known (Codex and Cursor don't say),
so on Windows every shell command is read as bash, PowerShell and cmd.exe, and
any hit stops it.

## Known limits

- Paths and commands built at run time (variables, string concatenation,
  `-join`, `[char]` codes) aren't followed: `$d = '.ss' + 'h'; gc ~\$d\$f`
  gets through, as `d=.ss; cat ~/${d}h/...` does in bash.
- A plain download (`certutil -urlcache`, `iwr -OutFile`) isn't stopped, as
  `curl -o` isn't on macOS; there is no Internet wall on Windows.
- `Remove-Item -Recurse` without `-Force`, `rm -rf`, `git clean -fdx` and
  `git reset --hard` aren't stopped.
- Process identity (which agent a process belongs to) has no code-signature
  check on Windows (macOS uses the Team ID); it isn't used by the hooks.
- Symlinks to protected files are resolved when the agent passes the link's
  path; creating a symlink needs Developer Mode or admin on Windows, so the
  unit test skips that check when it can't make one.
- The gateway (`kai gateway`) and the storage helper (`kai storaged`) are
  macOS features; on Windows they say they are not available. `kai demo` builds
  but hasn't been verified on Windows.
- The macOS-only text in a few `kai` messages (the Kai app, Settings pages)
  still shows on Windows in places: `kai allow`, `kai block` and friends say
  "Change this in Kai: Settings"; on Windows, edit the policy file instead.
