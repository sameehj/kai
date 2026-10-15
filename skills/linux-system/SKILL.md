---
name: linux-system
description: Core Linux system administration, diagnostics, and package management across all distros.
version: "1.0"
tags: [linux, system, diagnostics, packages, distro]
---

# Linux System Administration

## System Orientation

Run:

```bash
cat /etc/os-release
uname -a
hostnamectl
lscpu
free -h
df -h
lsblk
ps aux --sort=-%mem | head -20
ss -tlnp
systemctl list-units --state=running --type=service
```

## Package Management

Detect distro via `/etc/os-release`.

- ubuntu/debian: `sudo apt-get update && sudo apt-get install -y <pkg>`
- rhel/fedora/centos/rocky/amzn: `sudo dnf install -y <pkg>`
- alpine: `sudo apk add <pkg>`
- arch/manjaro: `sudo pacman -S --noconfirm <pkg>`
- suse/opensuse: `sudo zypper install -y <pkg>`

## USE Method Quick Pass

CPU: `mpstat -P ALL 1 3`, `vmstat 1 5`
Memory: `free -h`, `cat /proc/meminfo`
Disk: `iostat -xz 1 3`, `dmesg | grep -i 'error\|i/o'`
Network: `ss -s`, `ip -s link`

## Logs

```bash
journalctl --since "1 hour ago" --no-pager
journalctl -u <service> --since "1 hour ago" --no-pager
dmesg --time-format=iso | tail -50
```
