# KAI eBPF Architecture (MVP)

## Goal

Add a Linux-only eBPF execution path while keeping KAI cross-platform compilable.

## Components

- `pkg/ebpf/manager.go`
  - thread-safe lifecycle manager for loaded eBPF programs
  - `Load`, `Unload`, `List`, `Shutdown`
- `pkg/ebpf/manager_linux.go`
  - Linux implementation using `github.com/cilium/ebpf`
  - checks BTF and `/sys/fs/bpf`
- `pkg/ebpf/manager_stub.go`
  - non-Linux fallback returning `ErrNotSupported`

## Why this shape

- macOS/Windows developers can still compile and run tests
- Linux hosts can run real eBPF loading path
- future skills can reuse the same manager via primitive `exec` workflows

## Next implementation step

Add a real tcp-retransmit loader package that attaches to `tp/tcp/tcp_retransmit_skb` and streams ringbuf events to an analyzer.
