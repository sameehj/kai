---
name: process-inspector
description: Inspect running processes — top consumers, open files, network connections
metadata:
  kai:
    emoji: 🔍
    requires:
      bins: []
    os: [linux, darwin, windows]
---

# Process Inspector

## When to use
- "What's using my CPU/memory?"
- Investigating a slow or unresponsive system
- Finding which process owns a port
- Checking what a specific process is doing

## When NOT to use
- For network-level analysis (use network-check instead)
- For log analysis (use log-analyzer instead)

## How to use

### Top consumers
- Linux/macOS: `ps aux --sort=-%mem | head -15` for memory, `ps aux --sort=-%cpu | head -15` for CPU
- Quick overview: `top -b -n 1 | head -20` (Linux) or `top -l 1 | head -20` (macOS)

### Specific process
- By name: `ps aux | grep <process_name>`
- By PID: `ls -la /proc/<pid>/fd 2>/dev/null | wc -l` for open file count
- Open files: `lsof -p <pid> | head -30`
- Network connections: `lsof -i -p <pid>`
- Environment: `cat /proc/<pid>/environ | tr '\0' '\n'` (Linux)
- Command line: `cat /proc/<pid>/cmdline | tr '\0' ' '` (Linux)

### Port ownership
- Linux: `ss -tlnp | grep <port>` or `lsof -i :<port>`
- macOS: `lsof -i :<port>`

### Windows (PowerShell)
- Top processes: `Get-Process | Sort-Object CPU -Descending | Select-Object -First 15`
- By port: `netstat -ano | findstr <port>`

## Output guidance
When reporting, include PID, command, CPU%, MEM%, and any notable open files or network connections. If a process looks abnormal, say why.
