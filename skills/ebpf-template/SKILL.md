---
name: ebpf-template
description: Template for building eBPF-based observability skills
---

# eBPF Skill Template

Use this template when implementing a Linux kernel observability skill with eBPF.

## Requirements

- Linux kernel >= 5.10
- BTF available (`/sys/kernel/btf/vmlinux`)
- BPF fs mounted (`/sys/fs/bpf`)
- Capabilities: `CAP_BPF` + `CAP_PERFMON` (or root / `CAP_SYS_ADMIN`)

## Folder shape

```text
skills/<skill-name>/
  SKILL.md
  programs/
    <skill>.bpf.c
  examples/
    queries.txt
```

## Safety checklist

- Validate kernel and BTF before load
- Keep maps bounded
- Detach links on exit
- No writes to kernel state
- Handle unsupported kernels gracefully

## Suggested workflow

1. Build probe program in `programs/*.bpf.c`
2. Create Linux-only loader under `pkg/ebpf` (or dedicated package)
3. Add analyzer that converts raw events into concise findings
4. Expose execution via tool or skill trigger
5. Add tests for parser/analyzer logic (skip kernel-attached tests when unavailable)
