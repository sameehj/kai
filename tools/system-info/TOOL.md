---
name: system-info
description: Gather comprehensive system information — OS, CPU, memory, disk, services
metadata:
  kai:
    emoji: 💻
    requires:
      bins: []
    os: [linux, darwin, windows]
---

# System Info

## When to use
- Starting any investigation or debug session
- Understanding what machine you're on
- Checking resource availability before a build or deploy
- First tool to call when diagnosing any issue

## When NOT to use
- You already know the system details from a previous call in this session

## How to use

### Linux
- OS info: `cat /etc/os-release`
- Kernel: `uname -r`
- CPU: `lscpu | head -20`
- Memory: `free -h`
- Disk: `df -h`
- Running services: `systemctl list-units --type=service --state=running --no-pager | head -30`
- Uptime: `uptime`
- Load: `cat /proc/loadavg`

### macOS
- OS info: `sw_vers`
- CPU: `sysctl -n machdep.cpu.brand_string` and `sysctl -n hw.ncpu`
- Memory: `sysctl -n hw.memsize` (bytes)
- Disk: `df -h`
- Running services: `launchctl list | head -30`
- Uptime: `uptime`

### Windows (PowerShell / WSL)
- OS info: `systeminfo | Select-String "OS Name|OS Version"`
- CPU: `wmic cpu get Name,NumberOfCores`
- Memory: `systeminfo | Select-String "Total Physical Memory"`
- Disk: `Get-PSDrive -PSProvider FileSystem`

## Output guidance
Summarize findings concisely. Flag anything unusual: high memory usage, low disk space, high load, unexpected services.
