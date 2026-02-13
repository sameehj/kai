---
name: process-inspector
description: Inspect top CPU/memory consumers and process details
emoji: 🔍
os: [linux, darwin]
requires:
  bins: []
---

# Process Inspection

## When to use
- Identify top CPU/memory consumers
- Investigate a suspicious process
- Find which process owns a port

## How to use

```bash
exec {"command": "ps aux --sort=-%cpu | head -15"}
exec {"command": "ps aux --sort=-%mem | head -15"}
exec {"command": "lsof -i -P | head -20"}
```
