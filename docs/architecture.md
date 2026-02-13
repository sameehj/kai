# Architecture

KAI is a local assistant that follows the OpenClaw model.

```
kai gateway        # Persistent daemon (WebSocket server)
  ↓
Agent Runtime      # Execution loop
  ↓
Primitive Tools    # exec, read, write, ls, search, replace
  ↓
Skills             # SKILL.md documentation
  ↓
Session Storage    # Append-only persistence
```

## Core Principles

- Gateway is the single source of truth
- Agent loop controls execution
- Tools are primitive operations
- Skills are documentation
- Sessions define security boundaries
- Prompts are composed from files in the workspace
