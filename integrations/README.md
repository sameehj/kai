# Integrations

How Kai wires into each agent. `kai install` does this for you and keeps a
`.kai-bak` backup; this is the reference for what it writes and how to do it by
hand.

## Claude Code — `~/.claude/settings.json`

Kai adds hook entries (each tagged `"_kai": true` so `kai uninstall` can find
exactly its own):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook claude", "_kai": true }], "_kai": true }
    ],
    "PreToolUse": [
      { "matcher": "Bash|Read|Edit|Write|Grep|Glob",
        "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook claude", "_kai": true }], "_kai": true },
      { "matcher": "mcp__.*",
        "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook claude", "_kai": true }], "_kai": true }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook claude", "_kai": true }], "_kai": true }
    ]
  }
}
```

The hook reads the event JSON on stdin and prints a decision:
- `PreToolUse` → `{"hookSpecificOutput":{"permissionDecision":"deny",…}}` to block.
- `UserPromptSubmit` → `{"decision":"block",…}` to stop a prompt with secrets.
- `PostToolUse` → `{"hookSpecificOutput":{"additionalContext":"Kai warning: …"}}`
  to flag prompt-injection text.

## Codex — `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`)

*Implemented and unit-tested against Codex's published hook schemas (Codex CLI
0.142); not yet run against a live Codex session.*

Codex hooks use the same events, input fields and decision output as Claude
Code. Kai registers one handler per event, with **no matcher**, so it sees
every tool (shell, `apply_patch`, MCP) and decides itself:

```json
{
  "hooks": {
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook codex" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook codex" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/kai hook codex" }] }]
  }
}
```

- **No `_kai` marker:** Codex validates its hook config strictly, so Kai's
  entries are recognised by their command (`… hook codex`) when reinstalling or
  uninstalling. Your own hooks and other keys are kept.
- **Review once in Codex:** Codex asks you to review and trust new or changed
  hooks before it runs them ("Hooks need review"). Trust Kai's hooks the first
  time you open Codex after `kai install codex`.
- **What Kai checks:**
  - shell commands, whether sent as a string or an argv array: protected
    paths, uploads, and Kai's own control commands;
  - `apply_patch` edits: every `*** Add/Update/Delete File:` and
    `*** Move to:` path against your protected paths;
  - MCP tool arguments: secrets and blocked terms;
  - prompts: secrets and blocked terms;
  - tool results: prompt-injection warnings.
- Audit records use `"source":"codex"`.

## Cursor — `~/.cursor/hooks.json`

```json
{
  "version": 1,
  "hooks": {
    "beforeReadFile":       [{ "command": "/usr/local/bin/kai hook cursor", "failClosed": true, "_kai": true }],
    "beforeShellExecution": [{ "command": "/usr/local/bin/kai hook cursor", "failClosed": true, "_kai": true }],
    "beforeMCPExecution":   [{ "command": "/usr/local/bin/kai hook cursor", "failClosed": true, "_kai": true }],
    "beforeSubmitPrompt":   [{ "command": "/usr/local/bin/kai hook cursor", "failClosed": true, "_kai": true }]
  }
}
```

`failClosed: true` means a Kai crash blocks the action rather than letting it
through — the right default for a security hook. The handler returns
`{"permission":"deny",…}` (or `{"continue":false}` for a prompt) to block, and
`{"permission":"allow"}` otherwise.

## macOS / Linux service

`integrations/macos/com.kai.hookd.plist` and `integrations/linux/kai.service`
are placeholders for the v0.2 gateway/proxy daemon. v0.1 needs no background
service: the hooks run on demand when the agent calls them.

## Enterprise rollout

Both agents read hooks from managed locations too (Claude Code managed settings;
Cursor's `/Library/Application Support/Cursor/hooks.json` on macOS). Push the
same entries plus `~/.kai/policy` via MDM to deploy Kai across a fleet without
per-user setup. Kai Teams (roadmap) adds central policy and audit.
