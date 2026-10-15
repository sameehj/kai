# Changelog

## Unreleased
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
