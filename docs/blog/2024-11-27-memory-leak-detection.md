---
title: "Memory Leak Detection Without Spending Your Weekend"
date: 2024-11-27
author: KAI Team
tags: [memory, psi, debugging, automation]
problem: "Pods restart overnight but metrics show only small memory drift"
solution: "Layer PSI memory data with heap stats and agent reasoning"
---

# Memory Leak Detection Without Spending Your Weekend

The worst incidents are the slow ones. Resident memory climbs a little every hour, Grafana stays green, and by the time alarms fire you already have multiple pod restarts.

KAI's `flow.memory_leak_detector` automates the human loop:

1. **Collect PSI memory pressure** — `kernel.psi_memory` highlights compaction and reclaim stalls even when RSS still looks fine.
2. **Grab cgroup stats** — the `memory.cgroup_usage` sensor (ships separately) reads `memory.current`, `memory.high`, and cache breakdowns.
3. **Sample allocators** — BPF-based heap samples surface which binaries keep allocating.
4. **Agent reasoning** — Claude compares allocation deltas with PSI totals to determine if the leak is heap pressure, page cache, or IO backpressure.

---

## Example Output

```
Root Cause: Go HTTP worker pool leaking TLS buffers
Evidence:
- PSI memory: full avg10=7.2 (critical)
- Cgroup cache grew 2.3 GiB without request volume changes
- Heap profiles show 1.8 GiB in crypto/tls.(*Conn).Read
Recommendation: Upgrade service to Go 1.20.11 or enable HTTP/2 flow control
Confidence: 0.91
```

No graphs, no midnight kubectl loops. Just actionable guidance.

---

## Why PSI Matters Here

Leaks often hide because autoscalers add nodes before RSS alarms trigger. PSI sees the stall time caused by reclaim/compaction thrash — it does not care whether Prometheus scraped recently or whether RSS reset after a restart.

Feed PSI + heap stats into Claude and you finally get "users are timing out because page reclaim is eating 35% of wall clock" instead of "¯\\_(ツ)_/¯ memory looks ok."
