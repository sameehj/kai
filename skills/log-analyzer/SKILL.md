---
name: log-analyzer
description: Search system and application logs for errors and warnings
emoji: 📋
os: [linux, darwin]
requires:
  bins: []
---

# Log Analysis

## When to use
- Investigate crashes or failures
- Find recent errors and warnings

## How to use

```bash
exec {"command": "journalctl -p err -n 50 --no-pager"}   # Linux
exec {"command": "dmesg --level=err,warn | tail -50"}    # Linux
exec {"command": "log show --last 1h | tail -50"}        # macOS
```
