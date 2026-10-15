# Kai threat model

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
| Secret typed/pasted into a prompt | secret detectors | `UserPromptSubmit`, `beforeSubmitPrompt` |
| Company codename / confidential marker in a prompt | `term` / `rule` | same |
| Secret passed as an MCP tool argument | scan of tool input | `PreToolUse` `mcp__*`, `beforeMCPExecution` |
| Prompt injection in a tool result | injection patterns | `PostToolUse` (warn the agent) |
| Agent edits Kai's own policy/log | `protect ~/.kai` | path rules |

## What v0.1 does NOT stop (documented limits)

- **A determined script.** Hooks see the command string; obfuscation
  (`base64`, env indirection, an interpreter reading a file itself) can evade
  the pattern match. The OS-level **network and file walls** on the roadmap are
  what make exfiltration structurally impossible, not just pattern-detected.
- **Apps Kai doesn't hook.** GUI chat apps (ChatGPT desktop, Claude Desktop
  chat), browsers. The v0.2 decrypting proxy covers these.
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
  can warn rather than block (policy setting).
- **No secrets at rest.** The audit log records rule names and counts, never the
  matched secret.
- **Least surprise.** Kai touches only agent process actions and AI traffic;
  everything else on the machine is untouched.
