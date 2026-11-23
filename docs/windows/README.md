# Kai for Windows (preview)

Kai stops Claude Code, Codex and Cursor from reading secrets and running risky
commands, with the same checks as on macOS, and shows what they did. It runs
natively on Windows 10 and 11 (MSVC and .NET, no Cygwin, MSYS runtime or WSL).

What you get:

- **The agent hooks** (`kai.exe`): every tool call an agent reports is checked
  before it runs. These stop things.
- **Kai Watch** (`kaisvc.exe`, a Windows service): lists the hosts agents
  connect to, and optionally notes when a program an agent runs opens one of
  your protected files. This only watches.
- **The Kai app** (`Kai.exe`): a tray icon and a window with Now, Activity,
  Ask Kai and Settings, as on macOS.

## What Kai can and can't do on Windows

- **Hooks stop things; nothing else does.** There is no blocking at the
  operating-system level on Windows yet: no network filter and no file filter.
- **Internet is Watch only.** Kai Watch reads Windows' own event tracing
  (ETW): which agent process connected to which address, and the host name its
  DNS lookup returned. It doesn't read traffic and blocks nothing. A connection
  through a proxy on your computer shows as the proxy, not the site. A host
  name looked up by another program is marked as such.
- **Protected files outside the hooks are Watch only too** (off by default,
  Settings → Internet). When a script an agent wrote opens `~\.ssh\id_ed25519`,
  Kai records that it was *seen*. It doesn't stop it and can't tell what was
  read.
- **Hooks are a guardrail, not a sandbox.** They see the tool calls each agent
  reports. A script or program the agent writes and runs can read any file you
  can read and connect anywhere: the hook sees only `python read.py` or
  `.\t.ps1`. So can a path or command built at run time (`$d = '.ss' + 'h'`).
  See the rows marked *gets through* in [../ESCAPES.md](../ESCAPES.md).
- **Kai's own settings** (`%USERPROFILE%\.kai`) are protected from agents'
  tools, but a program an agent runs as you can still change files you own.
  Kai Watch's own state is in `%ProgramData%\Kai`, which only administrators
  can change.
- **A new release may trigger SmartScreen** ("Windows protected your PC")
  until it builds reputation, even when it's signed. Don't install a build
  that isn't signed by Kai's publisher.

## Install

Run `Kai-<version>-x64.msi` (one administrator prompt). It installs, for
every account on the computer:

| What | Where |
|---|---|
| The app | `C:\Program Files\Kai\Kai.exe` (Start menu: Kai) |
| The `kai` command and the hooks | `C:\Program Files\Kai\bin\kai.exe` (on the system PATH) |
| Kai Watch | `C:\Program Files\Kai\bin\kaisvc.exe`, service "Kai Watch", LocalSystem, starts with Windows |

Open Kai once: it connects every agent it finds (`kai install`), shows three
short welcome panes (Skip on each), and starts with Windows from then on
(Settings → Advanced). Codex runs Kai's hooks only after you trust them once:
open Codex, run `/hooks` and trust Kai's entries (again after each
reinstall).

**Uninstall:** Windows Settings → Apps → Installed apps → Kai. It stops and
removes Kai Watch, removes your agents' Kai hooks (`kai uninstall all`, for
the account that uninstalls) and your "Start with Windows" entry. Your Kai
folder (`%USERPROFILE%\.kai`: policy, audit log) stays, as on macOS.

### Where Kai keeps things

| What | Where |
|---|---|
| Policy, keys, grants, audit log, activity | `%USERPROFILE%\.kai` |
| Kai Watch's heartbeat | `%ProgramData%\Kai` (SYSTEM and Administrators write, users read) |
| Ask Kai chats (kept 30 days), the local model | `%LOCALAPPDATA%\Kai\chats`, `%LOCALAPPDATA%\Kai\models` |
| The app's own preferences | `%LOCALAPPDATA%\Kai\app.json` |

## Kai Watch

Kai Watch is the privileged part, so it does little: no window, no model, no
policy writes of its own. It reads the signed-in user's policy, records
through the same audit writer as the hooks (`source: network`, decision
`log`, at most one record per agent and host every 10 minutes, as on macOS),
and writes a heartbeat that `kai status` trusts only because no user can
write it.

- **Which processes:** Claude Code (`.local\bin\claude.exe`, and the copy the
  Claude desktop app runs), Codex (CLI and app) and Cursor, found by their
  install path; the Authenticode signer (Anthropic, OpenAI, Anysphere) is
  recorded as the identity when it matches. Every process they start is
  theirs. Processes are keyed by PID and start time, so a reused PID is never
  mistaken for an agent's. Other programs are never recorded.
- **When it stops:** if its ETW session dies, `kai status --json` says
  "Internet watching stopped" with the reason, the app shows it with
  **Restart**, and Kai Watch restarts the session by itself (5 s, backing off
  to a minute). If events were lost, it re-reads the process list.
- **Cost:** measured at 0.13% of one CPU core over 10 minutes (0.011% of a
  12-thread machine), 134,911 events, none lost
  ([TEST-RESULTS.md](TEST-RESULTS.md)).
- **Its pipe** (`\\.\pipe\kai-watch`, SYSTEM and the signed-in user only):
  `status`, `start`, `stop`, `mode off|watch` (`kai policy set egress …`, run
  as you). A request to change anything from inside an agent's process tree is
  refused. `kaisvc status` asks it from a terminal.
- **Switching user:** Kai Watch records for whoever is signed in at the
  console; when someone else signs in, it restarts for them.

## The app

Now, Activity, Ask Kai and Settings follow the macOS app. Every number comes
from `kai.exe` and the audit log; the app keeps no records of its own, so a
session's card and its Activity group always show the same counts. Each
record says how Kai knows it:

| Evidence | Meaning |
|---|---|
| Requested | the agent asked for it through its hook, before the tool ran |
| Tool-reported | the agent reported it after the tool ran |
| Seen | Kai Watch saw it on Windows itself, outside the hooks (watching only) |
| Confirmed | Kai's own decision: it stopped, asked or cleaned it |
| Unknown | no record says |

Kai is the subject when it acted ("Kai stopped Claude Code's read of .env"),
and Watch records say what Kai saw ("Kai saw Claude Code connect to
api.github.com"). Opening a stop shows why, what a retry would get now, and,
for a file read that isn't a private key or Kai's own settings, **Allow for 5
minutes**: one agent, one file, reads only, after you confirm with Windows
Hello (or your Windows password). Turning protection down (Internet off,
recording off) asks the same confirmation.

**Ask Kai** answers from Kai's records with a "Based on" line and the limits
of what Kai can see, written by Kai under the answer. Templates work at once;
the model chip offers a small local model (Qwen3.5 0.8B, ≈510 MB, the same
pinned file and SHA-256 as on macOS, downloaded only after you agree) that
rewords answers on your computer. A rewording that drops a number isn't used.

## Build from source

Needs Visual Studio 2022 Build Tools with the "Desktop development with C++"
workload, CMake 3.21 or later and Python 3 (the C side), the .NET 10 SDK (the
app) and WiX 5 (`dotnet tool install --global wix`, then
`wix extension add -g WixToolset.Util.wixext/5.0.2`) for the MSI.

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
dotnet build app\windows\Kai.Tests\Kai.Tests.csproj; app\windows\Kai.Tests\bin\x64\Debug\net10.0-windows10.0.19041.0\win-x64\Kai.Tests.exe
powershell -ExecutionPolicy Bypass -File scripts\release\build-windows-msi.ps1
```

`kai.exe` and `kaisvc.exe` use the static C runtime; the app is
self-contained, so the MSI needs nothing else installed. A release build
(`-DKAI_RELEASE=ON`, which the MSI script uses) ignores `KAI_HOME` and
`KAI_POLICY`, as on macOS. The live Kai Watch tests
(`tests\windows\run_watch_live.ps1`) and the MSI round trip
(`tests\windows\run_msi_roundtrip.ps1`) need an elevated PowerShell.

**Signing:** `build-windows-msi.ps1` signs every exe and DLL that is Kai's (or
unsigned) and then the MSI with signtool (SHA-256, RFC 3161 timestamp),
checks each with `signtool verify /pa /v` and writes `SHA256SUMS`. It takes
the certificate from the environment only (`KAI_SIGN_THUMBPRINT` for a cloud
key in the certificate store, such as DigiCert KeyLocker, SSL.com eSigner or
Certum SimplySign). Without one it builds `…-UNSIGNED.msi` for testing and
prints what's needed; `-RequireSigned` fails instead. It never publishes.

`kai install` refuses a `kai.exe` that sits inside a git checkout: it walks
up the folders looking for `.git`, stopping below your home folder and never
looking at a drive root (`C:\.git`). A dev build can override it with
`KAI_TEST_ALLOW_DEV_HOOK=1`.

Kai reads its policy file with either line ending, so saving it from Notepad
(CRLF) is fine.

### Kai's own settings

Everything Kai keeps for you is in one folder, as on macOS, so the always-on
"Kai's own settings" protection covers all of it: no agent may read or change
`%USERPROFILE%\.kai` through its tools, or Kai's program, or any agent's hook
settings (`.claude\settings.json`, `.codex\hooks.json`, `.cursor\hooks.json`,
and Codex's and Claude Code's machine-wide files under `%ProgramData%` and
`Program Files`).

`kai status --json` reports `"state": "degraded"` when the policy file's access
list lets another account change it (`policy.others_can_write`,
`policy.writable_by`), or when Internet watching is on but Kai Watch isn't
watching. Accounts that can change anything anyway (SYSTEM, Administrators)
and you don't count.

### Changing what Kai allows

In the app: Settings. Or edit `%USERPROFILE%\.kai\policy` (`kai init`
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

**Destructive commands (Windows shells, off by default).** Kai can stop
`Remove-Item -Recurse -Force` (and `ri`/`rm`/`del`/`rd` with those parameters),
`del /s /q`, `rd /s` / `rmdir /s`, `format <drive>`, `diskpart`,
`vssadmin`/`wmic` shadow-copy deletion, `cipher /w`, `Format-Volume`,
`Clear-Disk` and `Remove-Partition`, but only when the policy says
`on_destructive_command ask` (or `block`). It is off by default so Windows
and macOS behave the same. When on, Claude Code asks you; Codex and Cursor
deny. Bash's `rm -rf` is not stopped, on Windows or macOS.

Which shell a command is for isn't always known (Codex and Cursor don't say),
so on Windows every shell command is read as bash, PowerShell and cmd.exe, and
any hit stops it.

## Known limits

- Paths and commands built at run time (variables, string concatenation,
  `-join`, `[char]` codes) aren't followed: `$d = '.ss' + 'h'; gc ~\$d\$f`
  gets through, as `d=.ss; cat ~/${d}h/...` does in bash.
- A plain download (`certutil -urlcache`, `iwr -OutFile`) isn't stopped, as
  `curl -o` isn't on macOS; on Windows Kai Watch only records the connection.
- `Remove-Item -Recurse` without `-Force`, `rm -rf`, `git clean -fdx` and
  `git reset --hard` aren't stopped.
- The hooks don't check an agent's code signature (macOS uses the Team ID);
  Kai Watch records the Authenticode signer as the identity when it matches,
  and still tags an agent by its install path when it doesn't.
- Kai Watch records for the account signed in at the console. Uninstalling
  removes the Kai hooks of the account that uninstalls; other accounts keep
  theirs until they run `kai uninstall all`.
- The local model's wording (Qwen3.5 0.8B through LLamaSharp 0.30) hasn't
  been checked on Windows yet; Templates are what's tested.
- Symlinks to protected files are resolved when the agent passes the link's
  path; creating a symlink needs Developer Mode or admin on Windows, so the
  unit test skips that check when it can't make one.
- The gateway (`kai gateway`) and the storage helper (`kai storaged`) are
  macOS features; on Windows they say they are not available. `kai demo` builds
  but hasn't been verified on Windows.
- The macOS-only text in a few `kai` messages (the Kai app, Settings pages)
  still shows on Windows in places: `kai allow`, `kai block` and friends say
  "Change this in Kai: Settings"; on Windows, edit the policy file instead.
