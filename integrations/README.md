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
