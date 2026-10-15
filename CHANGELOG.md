# Changelog

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
