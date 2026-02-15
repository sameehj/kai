# 🚀 KAI — Kernel AI Assistant

**Kai is the AI assistant for Linux kernel and infrastructure debugging.**

Built on proven OpenClaw-style architecture, Kai focuses on one thing: helping engineers solve deep system problems fast.

---

## 😵 The Problem

Infra debugging today is painful:

- You juggle 10+ tools (`kubectl`, `bpftool`, `ss`, `perf`, `tcpdump`, `journalctl`, ...)
- You waste time searching commands and distro-specific package names
- eBPF is powerful, but hard to use under incident pressure
- Issues span layers (app → container → network → kernel), but workflows are fragmented

**Result:** slow incident response, high MTTR, and expert bottlenecks.

---

## ✅ The Solution

Kai combines:

- 🧠 **LLM reasoning**
- 🛠️ **Primitive tools** (`exec`, `read`, `write`, `ls`, `search`, `replace`)
- 📚 **Expert skills** (`SKILL.md`) for kernel, eBPF, Kubernetes, distro ops

You describe the issue in plain language. Kai runs structured diagnostics and returns:

1. probable root cause
2. confidence level
3. evidence from executed commands
4. next safe actions

---

## 💎 Benefits

### For SRE / DevOps / Platform teams
- ⚡ **Faster troubleshooting** (minutes instead of hours)
- 🧭 **Consistent workflows** across engineers
- 🧪 **Cross-distro clarity** (Ubuntu/RHEL/Amazon Linux/Arch)
- 🔬 **Optional eBPF deep dives** when basic checks aren’t enough

### For organizations
- 📉 Reduced MTTR
- 📈 Better operational reliability
- 🧷 Less dependency on a few kernel experts
- 🗂️ Institutional knowledge captured in reusable skills

---

## 🏗️ Architecture (Simple + Powerful)

```text
User Input
   ↓
Gateway (CLI / MCP / future channels)
   ↓
Agent Runtime (reasoning + tool orchestration)
   ↓
Primitive Tools (exec/files/search)
   ↓
Skill System (domain workflows in SKILL.md)
```

**Same runtime foundation. Different moat: skill depth.**

---

## 🧰 Current Skill Domains

- `skills/ebpf/` — kernel-level tracing and observability
- `skills/kubernetes/` — pod/service/network/CNI diagnostics
- `skills/kernel/` — patch/build/regression workflows
- `skills/distro/` — cross-distro install and compatibility flows
- `skills/embedded/` — Yocto/Buildroot/cross-compile (expanding)
- `skills/xdp/` — high-performance packet path workflows (expanding)

Flagship skill examples:
- `skills/ebpf/network-debug/SKILL.md`
- `skills/kernel/patch-check/SKILL.md`
- `skills/kubernetes/pod-network-debug/SKILL.md`
- `skills/distro/cross-distro-install/SKILL.md`

---

## ⚡ Quick Start

### 1) Build
```bash
go build -o ./build/kai ./cmd/kai
sudo install -m 755 ./build/kai /usr/local/bin/kai
```

### 2) Initialize workspace
```bash
cd ~/my-project
kai init
```

### 3) Start gateway
```bash
kai gateway
```

### 4) Start chat
```bash
kai chat
```

---

## 🛡️ Principles

- Primitive tools only (no magic hidden engines)
- Skills encode expert workflows transparently
- Runtime enforces policy and safety constraints
- Observation-first, reversible actions by default

---

## 🤝 Relationship to OpenClaw

Kai is a **specialized variant** in the same architectural family:

- OpenClaw: broad general automation
- Kai: deep kernel + infrastructure diagnostics

---

## 📜 License

MIT
