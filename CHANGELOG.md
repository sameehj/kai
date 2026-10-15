# Changelog

## Unreleased
- macOS menu-bar app (`make app`): status, per-agent switches, block
  notifications, recent activity, and a settings window for the policy.
- `kai status --json` and `kai policy show|set|add|remove`: comment-preserving,
  validated, atomic policy edits.
- Agents are blocked from running Kai's own control commands.
- `kai install` is idempotent (no duplicate hooks when run twice).
- The policy file follows `KAI_HOME` (it was always read from `~/.kai`).
- One-line installer (`install.sh`), release workflow, and a Homebrew formula.
- CI runs on `master` (it was set to `main`) and builds the macOS app.

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
