---
name: ebpf-core
description: Inspect and manage eBPF programs and maps using bpftool.
version: "1.0"
tags: [ebpf, bpftool, kernel, inspection]
requires:
  bins: [bpftool]
  root: true
---

# eBPF Core

```bash
sudo bpftool feature
sudo bpftool prog show
sudo bpftool map show
sudo bpftool net show
ls -la /sys/kernel/btf/vmlinux
```

BTF header generation:

```bash
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
```
