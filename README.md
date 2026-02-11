# 🧠 KAI — Your Coder AI Assistant

> An AI agent that lives on your machine and operates your development environment.

---

## What KAI Is

KAI is an AI-powered development assistant that runs locally on your machine.

It doesn't just suggest commands.

It runs them.
It builds your projects.
It compiles your kernel.
It runs your Yocto builds.
It inspects logs.
It fixes broken toolchains.
It creates new tools when needed.

KAI connects to any AI model (Claude, OpenAI, Gemini, Ollama) using MCP and gives it controlled access to your system.

You talk to the AI.
KAI executes.
The AI reasons and adapts.

No copy-paste.
No manual terminal gymnastics.
No context loss.

---

## Why KAI Exists

| Feature | Problem It Solves |
|---|---|
| Local-first MCP Gateway | You lose context and state between chats and tools |
| `kai.exec` (structured command runner) | Copy-paste terminal gymnastics; the AI can reason but can't act |
| Tool-as-Directory (TOOL.md + scripts) | Workflow DSLs rot; glue code becomes a platform |
| Hot-reload tools | "Install/restart/rebuild" kills iteration speed |
| Self-extension (`kai.tools.create`) | Your environment is unique; generic agents don't fit |
| System profile + requirements checking | Tools fail silently on wrong OS or missing binaries |
| Safety rails (blocklists, timeouts, output caps) | Local agents can become dangerous if misconfigured |
| Audit log + replayable runs | "What changed?" and "how did it run?" gets lost |
| Multi-model support | Lock-in and single-provider outages |
| Remote targets (SSH) | Your work spans dev machine, build server, and device |
| KaiHub tool registry | Everyone reinvents the same debugging scripts |

---

## Architecture

```
You → AI Model → KAI Gateway → Tools → Your Machine
```

**KAI Gateway** — Long-running daemon. Speaks MCP. Manages sessions. Enforces safety. Loads tools from disk. Hot-reloads on change.

**Tools** — Each tool is a directory with a `TOOL.md` and optional scripts. Tools describe what they do, contain executable logic, and return structured output. No workflow DSL.

**AI Model** — The AI decides which tool to call, interprets results, chains calls, and adapts dynamically. The AI is the orchestrator. KAI is the secure execution layer.

---

## Tool Format

```
~/.kai/tools/kernel-build/
├── TOOL.md          # What the AI reads (AgentSkills format)
├── scripts/         # Optional helper scripts
│   └── build.sh
├── bins/            # Optional binaries (added to PATH)
└── README.md        # Optional human docs
```

### TOOL.md Example

```markdown
---
name: kernel-build
description: Clone, configure, and build the Linux kernel
metadata:
  kai:
    emoji: 🐧
    requires:
      bins: [make, gcc, flex, bison]
    os: [linux]
---

# Kernel Builder

## When to use
- Building kernels from source
- Testing kernel configurations

## When NOT to use
- If you need a pre-built package (use apt/yum)

## How to use
1. Clone the kernel tree
2. Configure with make defconfig or a custom .config
3. Build with make -j$(nproc)
4. Check for errors in output

## Platform notes
- Ubuntu: install build-essential and libncurses-dev
- Fedora: install kernel-devel and ncurses-devel
- macOS: not available (Linux only)
```

The AI reads TOOL.md, understands what the tool does, and calls `kai.exec` for each step.
Community knowledge accumulates in the documentation — not in brittle code paths.

---

## Bundled Tools

KAI ships with tools that are useful to every developer on every platform:

| Tool | What It Does |
|---|---|
| `system-info` | OS, CPU, memory, disk, running services — every investigation starts here |
| `process-inspector` | Top processes by CPU/memory, open files, network connections |
| `log-analyzer` | Reads journalctl/dmesg/arbitrary logs, surfaces errors and warnings |
| `network-check` | DNS resolution, port checks, TCP state, basic latency |
| `build-helper` | Detects build systems (make/cmake/cargo/npm/gradle), checks deps, runs builds, parses errors |
| `tool-builder` | The `kai.tools.create` implementation — AI creates new tools on the fly |

Specialized tools (kernel build, Yocto, eBPF inspector, Docker debugger) live in KaiHub.

---

## What You Can Do

**Compile the Linux Kernel:**
> "Build the latest Ubuntu kernel locally."

**Run a Yocto Build:**
> "Build my custom Yocto image and tell me if anything failed."

**Inspect eBPF Programs:**
> "Show me what eBPF programs are running and if any look suspicious."

**Debug a Broken Build:**
> "My cross-compilation is failing. Figure out why."

**Profile Performance:**
> "Why is this process using so much CPU?"

**Create New Tools:**
> "Create a tool that checks Redis memory fragmentation."

The AI calls tools, reads results, chains investigations, adapts. No rigid workflows.

---

## Multi-Platform Support

KAI works across:

- **Linux** — all major distros (Ubuntu, Fedora, RHEL, Amazon Linux, Arch)
- **macOS** — full support
- **Windows** — via WSL or native shell
- **Embedded** — Raspberry Pi, ARM devices
- **Remote servers** — via SSH

Tools declare compatibility inside `TOOL.md`. The AI reads platform notes and adapts automatically.

---

## Safety

KAI enforces command blocklists, resource limits, timeout limits, output caps, and audit logging.

The AI can reason freely. KAI controls execution boundaries.

---

## AI Model Support

| Provider | Setup | Local |
|---|---|---|
| Claude (Anthropic) | `ANTHROPIC_API_KEY` | No |
| GPT-4 (OpenAI) | `OPENAI_API_KEY` | No |
| Gemini (Google) | `GOOGLE_API_KEY` | No |
| Ollama | `ollama run llama3` | Yes |

Works with Claude Desktop, Cursor, or any MCP-compatible client.

---

## KaiHub (Tool Registry)

A community-driven registry of reusable tools:

```bash
kai tools install linux-kernel-build
kai tools install yocto-monitor
kai tools install ebpf-inspector
kai tools install docker-debugger
```

Each tool includes documentation, compatibility matrix, safety notes, and real-world testing notes.

---

## Getting Started

### Install

```bash
curl -sSL https://kai.sh/install.sh | sh
```

Or build from source:

```bash
git clone https://github.com/sameehj/kai
cd kai
make build
sudo make install
```

### Start the Gateway

```bash
kai gateway
```

### Connect AI

Add to Claude Desktop MCP config:

```json
{
  "mcpServers": {
    "kai": {
      "command": "kai-mcp"
    }
  }
}
```

Then ask: *"Build the Linux kernel for Ubuntu."*

---

## Technology

- **Core:** Go — single binary, fast startup, tiny footprint
- **Tools:** Shell, Python, any executable
- **Protocol:** MCP over stdio and TCP
- **License:** Apache 2.0

---

## Roadmap

**Now:** Gateway daemon, MCP server, tool registry, CLI, tool hot-reload, self-extension, multi-platform

**Next:** KaiHub registry, notification integrations (Slack/Telegram/Discord), remote machine support, SSH multi-host

**Later:** Autonomous build monitoring, multi-machine coordination, persistent memory, shared team knowledge

---

## Contributing

Write tools. That's the easiest way to contribute. Create a directory with a `TOOL.md`, optionally add scripts, test with a connected AI agent, submit a PR.

---

## The Vision

Every developer machine should have an AI that understands its toolchain, can build and debug locally, adapts per platform, extends itself, and doesn't require copy-paste.

**KAI is that assistant.**

Not autocomplete. Not just suggestions.
An AI that actually operates your dev environment.
