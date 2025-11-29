---
layout: default
title: KAI Documentation
---

# KAI Documentation

KAI (Kernel Agentic Intelligence) is an autonomous investigation agent that orchestrates eBPF programs, system commands, and Claude analysis to diagnose kernel and infrastructure failures.

## Core Concepts

- **Flows**: YAML-defined investigation plans (`recipes/flows/`) that run sensors, agents, and actions sequentially.
- **Sensors**: Data collection steps backed by the system CLI, eBPF CO-RE programs, or observability APIs.
- **Agents**: Claude-powered reasoning steps that correlate multi-source telemetry into root-cause narratives.
- **Actions**: v0.1 logs recommended responses (execution automation lands in v0.2).

## Quick Start

```bash
git clone https://github.com/yourusername/kai.git
cd kai
make build
./bin/kaictl list-flows
sudo -E ./bin/kaictl run flow.network_latency_rootcause
```

See [README.md](../README.md) for prerequisites (Go 1.22+, Linux 5.8+, optional Anthropic key) and troubleshooting tips.

## Blog

Visit [the KAI Blog](/kai/blog/) for deep dives on PSI, eBPF, Hubble, and real-world investigations.
