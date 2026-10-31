# Kai threat model

> **Build order superseded by [`docs/security/RECONCILED-PLAN.md`](security/RECONCILED-PLAN.md)** (Security Plan v1.0, frozen Oct 31, 2026). This document keeps its specs and tests; where it conflicts with the spec, the spec wins.

**Assumption:** no model, router, or agent is trustworthy. The developer is
trusted; the agent acting on their behalf is not, because it can be hijacked by
content it reads (a README, a web page, an MCP tool result) or simply make a
mistake with the developer's full privileges.

## What Kai v0.1 (hooks) stops

| Threat | Mechanism | Caught by |
|---|---|---|
| Agent reads `~/.ssh`, `.env`, cloud keys via a tool | `protect` path rules | Claude `PreToolUse`, Cursor `beforeReadFile` |
| Agent reads a protected path via a shell command | path scan of the command line | `PreToolUse` Bash, `beforeShellExecution` |
| Data exfiltration (`curl -d @file`, `… | sh`, `nc`, `scp`) | upload patterns | `PreToolUse` Bash, `beforeShellExecution` |
| Agent reads a file holding secrets, customer names or other blocked data (Read tool, `cat`, `grep`, …), sending it to the model | contents checked against secrets, `term`, `rule` (`on_file_secret`: ask / block / warn; your `block` terms always block) | `PreToolUse` Read/Grep/Bash, `beforeReadFile`, `beforeShellExecution` |
| Secret typed/pasted into a prompt | secret detectors | `UserPromptSubmit`, `beforeSubmitPrompt` |
| Company codename / confidential marker in a prompt | `term` / `rule` | same |
| Secret passed as an MCP tool argument | scan of tool input | `PreToolUse` `mcp__*`, `beforeMCPExecution` |
| Prompt injection in a tool result | injection patterns | `PostToolUse` (warn the agent) |
| Agent edits Kai's own policy/log | `~/.kai` is always protected | path rules |
| Agent disables its own hooks (edits `~/.claude/settings.json`, `.cursor/hooks.json`, `.codex/hooks.json`/`config.toml`, project copies) | built-in protected paths, not overridable by policy | `PreToolUse` (Edit/Write/MultiEdit/NotebookEdit, Bash), `beforeShellExecution` |
| Agent runs Kai's settings commands (`k=kai; $k uninstall`, `sh -c '…'`) | shell reader looks at executed commands | `PreToolUse` Bash, `beforeShellExecution` |
| Agent makes Terminal (or iTerm, System Events, …) run a command, outside its own process tree (`osascript … do script`, `open -a Terminal x.sh`, `open x.command`) | `terminal_control`: the script text, a piped-in script or a script file names a terminal app | `PreToolUse` Bash, `beforeShellExecution` |

## What v0.1 does NOT stop (documented limits)

- **A determined script.** Hooks see the command string; obfuscation
  (`base64`, env indirection, an interpreter reading a file itself) can evade
  the pattern match. The OS-level **network and file walls** on the roadmap are
  what make exfiltration structurally impossible, not just pattern-detected.
- **Apps Kai doesn't hook.** GUI chat apps (ChatGPT desktop, Claude Desktop
  chat) and AI chat sites in a browser (the Chrome extension was removed in
  0.2.0-preview.1, Security Plan v1.0); the network wall sees GUI apps'
  connections only when an agent starts them.
  A decrypting proxy that would read their prompts is on hold.
- **Cloud agents.** Cursor background agents and Codex cloud run on vendor
  servers; their traffic never reaches this machine.
- **A root-level compromise.** Kai is not a defense against malware already
  running as root or an attacker who can disable it with admin rights. Its claim
  is protection against an unprivileged, possibly-hijacked agent.
- **Prompt-injection detection is best-effort.** Research shows adaptive attacks
  beat detectors >85% of the time, so injection findings are **warnings**, never
  the only gate. The walls are the real control.

## Design choices that follow from this

- **Walls decide, judges warn.** Deterministic rules (paths, upload patterns,
  term/secret redaction) block. Pattern/ML detection only flags.
- **Fail closed on policy, configurable elsewhere.** A broken policy denies
  agent actions. For normal operation, secrets fail closed; low-risk unknowns
  can warn rather than block (policy setting). Hooks are installed
  fail-closed: if Kai's program is missing or crashes, Claude Code, Codex and
  Cursor block the action (for Claude Code and Codex only on `PreToolUse` and
  `UserPromptSubmit`; exit 2 on `Stop` would keep the agent from stopping).
  **Not yet true:** the network wall allows all traffic when it can't read the
  policy (traced in [SECURITY-VALIDATION.md](SECURITY-VALIDATION.md)).
- **No secrets at rest.** The audit log records rule names and reasons, never
  the matched secret. Decisions also keep an excerpt of what was blocked (the
  command, path or part of the prompt, up to 300 characters) so a person can
  see why; every rule match in it is replaced by `[REDACTED by Kai: …]` first.
  That redaction is only as good as the detectors: a secret Kai doesn't
  recognize stays in the excerpt. The log is local and readable only by you
  (0600, under `~/.kai`, which agents can't read); `audit_context off` keeps
  just rules and reasons, and with secret detection off no excerpt is kept.
- **Exceptions are narrow and visible.** "Not a threat" adds
  `exempt <rule> <glob>`: that one rule skips that one command, every other
  check still runs, every use is logged, and Kai's own protection can't be
  exempted. Agents can't add exceptions (`kai policy` is self-protected).
- **Reports are never sent.** `kai report` writes a local file and a GitHub
  issue link; nothing leaves the machine unless the user opens it and submits.
- **Least surprise.** Kai touches only agent process actions and AI traffic;
  everything else on the machine is untouched.
