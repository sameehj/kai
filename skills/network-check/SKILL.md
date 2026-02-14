---
name: network-check
description: Diagnose DNS, port connectivity, and latency issues
emoji: 🌐
os: [linux, darwin]
requires:
  bins: []
---

# Network Diagnostics

## When to use
- Connection failures
- DNS or latency issues

## How to use

```bash
exec {"command": "nslookup example.com"}
exec {"command": "ping -c 4 example.com"}
exec {"command": "nc -zv example.com 443"}
exec {"command": "curl -I https://example.com"}
exec {"command": "curl -s https://lore.kernel.org/bpf/ | head -50"}
```
