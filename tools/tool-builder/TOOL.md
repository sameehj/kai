---
name: tool-builder
description: Create new KAI tools — write TOOL.md and optional scripts for any task
metadata:
  kai:
    emoji: 🧰
    requires:
      bins: []
    os: [linux, darwin, windows]
---

# Tool Builder

This is a meta-tool. Use it to create new tools for KAI.

## When to use
- User asks for functionality that no existing tool covers
- A task is repeated often and should be codified
- Creating project-specific or environment-specific tooling

## When NOT to use
- An existing tool already covers the task
- The task is a one-off that doesn't warrant a permanent tool

## How to create a tool

Use the `kai.tools.create` MCP method. This creates a directory under the configured tools path.

Every tool needs at minimum a `TOOL.md` file. Optionally include:
- `scripts/` directory with shell scripts, Python scripts, or any executable
- `bins/` directory with binary executables (these get added to PATH)
- `README.md` for human documentation

### TOOL.md format

Use YAML frontmatter for metadata, then natural language instructions:

```
---
name: <tool-name>
description: <one-line description>
metadata:
  kai:
    emoji: <emoji>
    requires:
      bins: [<required-binaries>]
    os: [linux, darwin, windows]
---

# <Tool Name>

## When to use
- <situation 1>
- <situation 2>

## When NOT to use
- <situation where another tool is better>

## How to use
<step-by-step instructions using commands>

## Platform notes
- <distro-specific notes>
```

### Guidelines for good tools
- Keep TOOL.md under 100 lines
- Be specific about commands — include the exact command to run
- Include platform-specific variations where they differ
- Document what the output means, not just how to get it
- Add "When NOT to use" to prevent misuse
- Test the commands on at least one platform before shipping

### After creation
KAI hot-reloads tools automatically. The new tool is immediately available to the AI agent without restart.
