---
layout: default
title: KAI Documentation
---

# KAI Documentation

KAI (Kubernetes AI Investigator) uses eBPF data sources, Kubernetes context, and AI reasoning to diagnose production issues in seconds.

- **Flows** orchestrate sensors, agents, and actions stored in `recipes/flows`.
- **Sensors** gather kernel, system, and cloud telemetry from `recipes/sensors`.
- **Agents** (Claude-powered) correlate evidence into root-cause reports.

## Quick Start

```bash
go build ./cmd/kaictl
./bin/kaictl list-flows
./bin/kaictl run-flow flow.cpu_saturation_detector
```

## Blog

Visit [the KAI Blog](/kai/blog/) for deep dives on PSI, Hubble, Tetragon, and more.
