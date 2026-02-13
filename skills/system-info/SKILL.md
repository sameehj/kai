---
name: system-info
description: Get complete system profile (OS, distro, kernel, resources)
emoji: 💻
os: [linux, darwin]
requires:
  bins: []
---

# System Information Investigation

## When to use this skill

Use this when you need to understand:
- What operating system you're on
- Distribution and version
- Kernel version
- Available memory and disk space
- Shell environment

## How to use

### Basic system info
```bash
exec {"command": "uname -a"}
exec {"command": "lsb_release -a"}  # Linux only
exec {"command": "sw_vers"}         # macOS only
```

### Memory info
```bash
exec {"command": "free -h"}         # Linux
exec {"command": "vm_stat"}         # macOS
```

### Disk info
```bash
exec {"command": "df -h"}
```

## Platform-specific notes

### Linux
- Use `lsb_release` for distro info
- Use `free` for memory
- Check `/proc/cpuinfo` for CPU details

### macOS
- Use `sw_vers` for OS version
- Use `sysctl` for system info
- Use `vm_stat` for memory

## Output storage

Store comprehensive results in:
```
~/.kai/logs/<session>/system-info-YYYY-MM-DD.txt
```
