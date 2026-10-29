# Changelog

## 0.2.0-preview.1 (release candidate, 2026-10-29)
Kai Preview checks supported actions inside Claude Code, Codex and Cursor before
they run. It is an extra safety layer, not isolation or OS-level enforcement.
Release notes: docs/release/v0.2.0-preview.1.md.
- Stop messages say what, why, and the exact narrow command where Kai identified
  the target. The verb is "stopped" (Preview 1 never says "blocked" or "protected").
- Narrow terminal grants: `kai allow-file --read/--write`, `allow-fetch`, `allow-mcp`,
  `allow-upload --to`, `block`, `rules`, `undo`. Each is one agent, one operation, one
  target, with an expiry. Files are pinned to the exact file. They refuse inside an
  agent; with the Kai app installed, use the app.
- `kai status` / `kai doctor` per agent: Installed, Configured, Trusted, Self-test,
  Live verification. `kai demo` and `kai demo --live`.
- Policy integrity: a fingerprint on every Kai write. Malformed, unrecognized rule,
  changed outside Kai and missing are reported separately. A missing policy that Kai
  wrote stops tool actions.
- Claude Code's web fetch is checked (URL secrets, `kai block`, `on_fetch block`).
  MCP tools work without the app (`kai allow-mcp`).
- docs/COVERAGE.md: event, input, stage, can block, bypasses, and live or synthetic
  evidence per agent and action.
- Chrome extension 0.2.0: no `tabs` permission. The popup shows the sites checked,
  redacted before sending, not checked, and Not a secret.
- Installer: welcome and readme pages with the contract. Postinstall registers the
  browser and refreshes Kai's hooks where they are already installed, for the
  signed-in user (backups kept, changes logged).
- App (pilot): GitHub, package registries and Apple developer services are no longer
  category switches. Each host is asked about, with a plain description from a host
  catalog, and old switch settings migrate to exact per-host rules
  (<kai home>/migrations/channels.txt).

## Unreleased
- Storage wall can now be loaded and enforce on a dev machine: the ES
  extension is embedded by the storage build (`make try-app-storage`), the
  menu has a Storage wall on/off (one System Settings approval), and the
  app's Advanced settings pick Watch (notify, logs would-block) or Block
  (deny). Enforcement is compiled in for that build; distribution still
  excludes the extension until Apple approves, so it can't ship yet. Load in
  Watch first; move to Block only after it looks right.
- Simpler main screen: per-agent "Protected" on/off (no "hooks" jargon), with
  a "System protection (all agents)" section for the network and storage
  walls, which are machine-wide. Response/mode granularity stays in Settings.
- Storage wall, OS client: an Endpoint Security system extension
  (`app/macos/Storage`, built with `make app-storage`) that tags agent
  processes at exec and checks their file opens against the same decision
  engine. It defaults to notify mode (observe and log "would block", no AUTH
  deadline, can't stall the machine); real blocking is compiled only with
  KAI_STORAGE_ENFORCE and meant for VM testing first. Built from a separate
  xcodegen overlay so `make app`, CI and the distribution build never include
  it or need the ES entitlement. Dev entitlement assigned; distribution
  pending Apple (request JQJJ3T6Z6V), so it can't ship yet. Compiles and
  links; not yet load-tested on a device.
- Storage wall, decision engine: `kai_storage_open_allowed` decides whether an
  agent process may open a file, reusing the same protected-path rules as the
  hooks. Off by default (`storage off|log|block`); enforcement needs Apple's
  Endpoint Security entitlement, so it ships dark. `kai storaged` previews the
  decisions now from `sudo eslogger open` (observe-only, no entitlement). The
  ES client (app/macos/Storage) is written but left out of the build until the
  entitlement arrives. Unit tests in tests/storage.
- App updates no longer replace the network extension: the extension has its
  own version (KAI_EXT_VERSION), bumped only when its code changes, so an
  app-only update never tears down the content filter or drops agents' live
  connections. The app re-activates the extension only when that version rose.
- Files the agent reads are checked: before the Read/Grep tools or a reading
  command (`cat`, `grep`, `head`, …), Kai scans the file for secrets, company
  terms and rules. `on_file_secret` (shown in the app, but never applied
  before) now works, with a new default: **ask**. Claude Code shows its own
  approval prompt; Cursor asks for shell commands; Codex and Cursor file
  reads block. Your own `block` terms and rules always block. "Not a threat"
  on such a block adds a `file_contents` exception for that file.
- `on_upload ask` now asks (Claude Code, Cursor) or blocks (Codex). It used
  to mean "warn" and let the command run.
- Browser extension: when Kai can't check a message, it says why and what
  fixes it (reload this page, set Kai up for this browser, ...), and the
  popup shows the error.
- Live health checks: `kai status --json` now runs each installed hook the way
  the agent would (program present, fail-closed, a test request is denied)
  and pings the browser helper, reporting `working` and `problem`. Probes
  aren't recorded. The app shows a broken integration as a problem instead
  of green, and says "Protection on" rather than "All protected".
- Codex, measured live (CLI 0.162.1): Kai blocks once its hooks are trusted
  in Codex's `/hooks`. Codex silently skips untrusted or changed hooks, so
  after this release's hook change Codex needs Kai's hooks trusted again.
  `tests/codex/run_codex_check.sh` checks it.
- Browser extension: a red "!" on the toolbar icon whenever Kai can't be
  reached (checked at browser start and on every message); Kai's helper
  accepts a Chrome Web Store ID too (`KAI_STORE_EXTENSION_ID`);
  `make chrome-zip` builds the store upload; listing and permissions in
  `docs/CHROME_STORE.md`; privacy policy at `/privacy/` on the site.
- Fail-closed hooks: Claude Code and Codex `PreToolUse`/`UserPromptSubmit`
  hooks now block (exit 2, with a reason) when Kai's program is missing,
  crashes or can't answer; they used to let the action run. `Stop` and
  `PostToolUse` are left as they were. Re-run `kai install` (the app does it
  after an update) to upgrade existing hooks.
- `terminal_control`: agents can't make Terminal, iTerm, System Events or
  another terminal app run commands for them (`osascript … do script`,
  keystrokes, a piped-in or file script, `open -a Terminal x.sh`,
  `open x.command`). Those commands ran outside the agent's process tree,
  past the hooks and the network wall. Exemptable like any rule.
- Network wall: `egress_allow` takes IP addresses, CIDR ranges and `:port`
  (`10.0.0.0/8`, `203.0.113.5:22`, `db.example.com:5432`); loopback is always
  allowed. In Block mode a connection with no host name on a port other than
  80/443 is now dropped unless an address entry allows it (it was only
  logged). The app's "Allow" works for such `ip:port` notices too.
- Security validation (`docs/SECURITY-VALIDATION.md`, `make validation`): a
  measured verdict (BLOCKED / BYPASSABLE / DETECTED / NOT SUPPORTED) for ten
  risks, from the escape suite, now 56 cases including destroying work,
  databases, MCP tools, planted README instructions and Kai not running. Each
  local case is also replayed for real without Kai in a throwaway home with
  fake secrets, with a control run proving its check can tell.
  `tests/network/run_network_check.py` records a live network-wall run.
  First findings: Block mode drops an agent's web connections to unknown
  hosts; DNS, no-hostname connections on other ports and processes that leave
  the agent's tree get through; Claude Code and Codex hooks failed open when
  Kai's program was missing (fixed above); no rule for destructive commands
  yet.
- Activity you can act on:
  - Audit records carry the tool, a redacted excerpt of the command, path or
    prompt, the part that matched, the session and folder (`audit_context
    on|off`). After a block, the session's next event adds a note: retried,
    did something else, or stopped (Claude Code's `Stop` hook is installed).
  - `kai log show` prints decisions in words; `kai report <id>` writes a
    false-positive report and a GitHub issue link without sending anything.
  - `exempt <rule> <glob>` exceptions (`kai policy add|remove exempt`): one
    rule skips one command, other checks still run, each use is logged, and
    Kai's own protection can't be exempted.
  - App: the Activity page shows what was blocked, the match highlighted,
    what the agent did next, and "Not a threat" (exception, allow the file,
    or report); notifications are merged per rule; notification permission
    is asked when first needed, not at launch.
- Upload rules match commands, not mentions: they run on a per-pipeline view
  of the command (heredoc bodies, comments and arguments that only mention
  `nc` no longer block), echoed text piped into a shell is read too, and the
  old default patterns in existing policy files are upgraded automatically.
- Escape suite (`tests/escape`, `make escape`): ways an agent might reach
  a secret, send data out or switch Kai off, with what the hooks do today
  and which layer is meant to close the rest. Runs in
  `make test`; results published in `docs/ESCAPES.md`.
- README leads with what Kai does for you and its current security status;
  roadmap reordered (escape suite, Block mode, notarized build, then the
  storage wall); the decrypting proxy is on hold.
- Review fixes:
  - Agents can't disable Kai by editing their own hook settings: those files
    (and project-level copies) and `~/.kai` are always protected. Claude Code
    hooks now cover MultiEdit, NotebookEdit and LS, and Grep/Glob/LS paths.
  - Audit log: only decisions are recorded (not every allowed call), appends
    read just the file's tail, and the log rotates at 8 MB.
  - Prompt-injection warnings weigh evidence and carry a confidence level and
    a redacted excerpt; `tests/corpus` measures misses and false alarms.
  - The generic secret rule checks that a value looks like a secret.
  - Shell commands are read like a shell would (quotes, `$()`, backticks,
    `sh -c`, `eval`, heredocs) for path and self-protection checks.
  - Network wall: a flow's CDN name no longer hides the requested host; the
    TLS server name decides, and either name being allowed is enough.
  - Browser extension: never sends unchecked silently when Kai is
    unreachable; installs to `~/.kai/browser-extension`.
  - The app re-applies agent setup after an update; `make fuzz`.
- Browser extension (`integrations/browser`) for ChatGPT, Claude.ai, Gemini,
  DeepSeek, Perplexity, Copilot, Mistral, Grok and Poe: cleans secrets on
  paste and holds sensitive messages with Redact and send / Send anyway / Edit.
  `kai install|uninstall chrome` registers a native-messaging host with
  Chrome, Brave, Edge and Chromium; `kai status` reports whether the
  extension is loaded. The extension ships in Kai.app and `make install`.
- `kai policy add|remove agent <name> exe|arg|team <pattern>` to recognize
  other AI agents; `kai policy show --json` lists them.
- Menu-bar app: Chrome card with a "Load the extension to finish" helper.
- Codex hooks: `kai install|uninstall codex` writes `$CODEX_HOME/hooks.json`
  (default `~/.codex/hooks.json`; `install all` includes Codex when `~/.codex`
  exists), and `kai hook codex` checks shell commands (string or argv array),
  `apply_patch` paths, MCP arguments and prompts. `kai doctor`, `kai status`
  and the menu-bar app report Codex. Not yet tested with a live Codex session.
- Hook policy errors now answer in the shape each event accepts (Codex
  validates hook output strictly).
- macOS menu-bar app (`make app`): status, per-agent switches, block
  notifications, recent activity, and a settings window for the policy.
- `kai status --json` and `kai policy show|set|add|remove`: comment-preserving,
  validated, atomic policy edits.
- Agents are blocked from running Kai's own control commands.
- `kai install` is idempotent (no duplicate hooks when run twice).
- The policy file follows `KAI_HOME` (it was always read from `~/.kai`).
- One-line installer (`install.sh`), release workflow, and a Homebrew formula.
- CI runs on `master` (it was set to `main`) and builds the macOS app.
- `kai gateway`: local AI gateway that redacts/replaces/blocks request content
  for Anthropic, OpenAI and OpenRouter APIs and streams replies back.
- Network-wall engine: agent identity (`agent` lines, `kai agent-of`), egress
  allowlist (`egress`, `egress_allow`) and a TLS SNI parser. Design in
  `docs/WALLS.md`.
- Build now links libcurl (system libcurl on macOS).

## v0.1.0 — unreleased
First cut. Hook-based protection for Claude Code and Cursor.

- Policy engine with `protect`/`allow` paths, `secrets`, `term`, `rule`,
  `rule_upload`, `rule_injection`, and behaviour switches.
- Built-in secret detectors (SSH/PEM keys, AWS, GitHub, GitLab, Slack, Stripe,
  Google, OpenAI, Anthropic, OpenRouter, JWT, DB URLs, generic assignments).
- Redact / replace / block for secrets and company terms.
- Protected-path and data-exfiltration checks for file reads and shell commands.
- Prompt-injection warnings on tool results.
- Tamper-evident, hash-chained audit log with `kai log verify`.
- `kai install/uninstall` safely merge into agent settings (keep a backup, tag
  entries, remove only Kai's own on uninstall).
- Builds on macOS and Linux; unit + hook tests; AddressSanitizer clean.
