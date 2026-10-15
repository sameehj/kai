---
name: bpftrace
description: Dynamic tracing with bpftrace one-liners and scripts.
version: "1.0"
tags: [ebpf, tracing, bpftrace, observability]
requires:
  bins: [bpftrace]
  root: true
---

# bpftrace

Use `exec.run`/`exec.stream` with bounded runs (`--timeout`).

## Install

- Ubuntu/Debian: `sudo apt-get install -y bpftrace`
- RHEL/Fedora: `sudo dnf install -y bpftrace`
- Arch: `sudo pacman -S --noconfirm bpftrace`
- Alpine: `sudo apk add bpftrace`

## Useful one-liners

```bash
sudo bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }' --timeout 5
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }' --timeout 10
sudo bpftrace -e 'kprobe:tcp_retransmit_skb { @[kstack] = count(); }' --timeout 10
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("%s -> %s\n", comm, str(args->filename)); }' --timeout 10
```
