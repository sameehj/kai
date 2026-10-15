---
name: cilium-ebpf-go
description: Write, compile, and load CO-RE eBPF programs with cilium/ebpf.
version: "1.0"
tags: [ebpf, go, cilium, co-re]
requires:
  bins: [go, clang, bpftool]
---

# cilium/ebpf Go

Workflow:
1. Write `.bpf.c` program.
2. Generate bindings with `bpf2go`.
3. Load/attach with Go (`github.com/cilium/ebpf`).
4. Validate with verifier logs and `bpftool` inspection.
