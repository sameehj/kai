---
name: build-helper
description: Detect build system, run builds, and parse build errors
emoji: 🏗
os: [linux, darwin]
requires:
  bins: []
---

# Build Helper

## When to use
- Build failures
- Unknown build system

## How to use

```bash
exec {"command": "ls"}
exec {"command": "make -j$(nproc)"}
```
