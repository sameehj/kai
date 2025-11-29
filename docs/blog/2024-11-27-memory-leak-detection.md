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

1. **Collect `/proc/meminfo` snapshots** — the `memory.meminfo` sensor runs twice with a 60-second delay to capture deltas.
2. **List top RSS processes** — `memory.top_rss` pinpoints binaries consuming the most resident memory.
3. **Agent reasoning** — Claude compares before/after memory stats with RSS leaders to determine whether the drift is heap growth, page cache churn, or normal workload variance.

Future versions will add PSI + cgroup pressure sensors, but even today the flow can answer "who is leaking?" without manual shell work.

---

## Example Output

```
Root Cause: Node exporter leaking goroutines
Evidence:
- MemAvailable dropped 420 MiB over 60s while workload stayed flat
- Swap unchanged (healthy)
- Top RSS shows node_exporter +420 MiB delta, next process +12 MiB
Recommendation: Recycle node_exporter pod or roll to v1.7.0
Confidence: 0.89
```

No graphs, no midnight kubectl loops. Just actionable guidance.

Run it locally:

```bash
git clone https://github.com/yourusername/kai.git
cd kai
make build
sudo -E ./bin/kaictl run flow.memory_leak_detector
```

---

## Why PSI Matters Here

Leaks often hide because autoscalers add nodes before RSS alarms trigger. PSI sees the stall time caused by reclaim/compaction thrash — it does not care whether Prometheus scraped recently or whether RSS reset after a restart.

Feed PSI + heap stats into Claude and you finally get "users are timing out because page reclaim is eating 35% of wall clock" instead of "¯\\_(ツ)_/¯ memory looks ok."
