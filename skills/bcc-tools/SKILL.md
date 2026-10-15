---
name: bcc-tools
description: Use high-value BCC tools for performance and latency investigations.
version: "1.0"
tags: [ebpf, bcc, performance, tracing]
requires:
  bins: [execsnoop-bpfcc]
  root: true
---

# BCC Tools

Install:
- Ubuntu/Debian: `sudo apt-get install -y bpfcc-tools`
- RHEL/Fedora: `sudo dnf install -y bcc-tools`

High-value tools:
- `execsnoop-bpfcc`
- `runqlat-bpfcc`
- `biolatency-bpfcc`
- `tcpconnect-bpfcc`
- `tcpretrans-bpfcc`
- `offcputime-bpfcc`
