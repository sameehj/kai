# KAI - Local AI Assistant

KAI is a Go implementation of the OpenClaw architecture, optimized for development workflows.

## Philosophy

KAI follows the OpenClaw model:
- **Primitive tools** (exec, read, write, ls, search, replace)
- **Skills as documentation** (SKILL.md files guide behavior)
- **Runtime enforcement** (LLM suggests, runtime enforces)
- **Session-based security** (main vs dm vs group)
- **File-composed prompts** (AGENTS.md, SOUL.md, TOOLS.md)

The AI model provides intelligence; KAI provides the operating system.

## Quick Start

### Install
```bash
go build -o ./build/kai ./cmd/kai
sudo install -m 755 ./build/kai /usr/local/bin/kai
```

### Initialize Workspace
```bash
cd ~/my-project
kai init
```

### Start Gateway
```bash
kai gateway
```

### Chat
```bash
kai chat
```

## Architecture

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

## Workspace Structure

```
~/project/
  AGENTS.md        # Core agent configuration
  SOUL.md          # Personality (optional)
  TOOLS.md         # Tool usage conventions (optional)
  skills/          # Project-specific skills
    my-skill/
      SKILL.md

~/.kai/
  kai.json         # Configuration
  sessions/        # Session storage
  memory/          # Memory system
  logs/            # Execution logs
  artifacts/       # Build outputs
```

## Skills

Skills are documentation that guides the agent:

```markdown
---
name: kernel-build
description: Build Linux kernel safely
---

# Linux Kernel Build

## When to use
Building kernel from source

## How to use
```bash
exec {"command": "make menuconfig"}
exec {"command": "make -j$(nproc)"}
```
```

## Configuration

Edit `~/.kai/kai.json`:

```json
{
  "llm": {
    "provider": "anthropic",
    "model": "claude-sonnet-4-5",
    "api_key_env": "ANTHROPIC_API_KEY"
  },
  "policy": {
    "allow": ["exec", "read", "write", "ls", "search", "replace"],
    "blocklist": ["rm -rf /", "dd if="]
  }
}
```

## Comparison to OpenClaw

| Feature | OpenClaw | KAI |
|---------|----------|-----|
| Language | TypeScript | Go |
| Gateway | Node.js WebSocket | Go WebSocket |
| Tools | Primitives | Primitives |
| Skills | SKILL.md | SKILL.md |
| Sessions | Append-only JSON | Append-only JSON |
| Prompts | File-composed | File-composed |
| Channels | Many (Telegram, WhatsApp, etc.) | CLI + MCP (more planned) |

## License

MIT
