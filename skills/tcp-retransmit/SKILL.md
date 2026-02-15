---
name: tcp-retransmit
description: Track TCP retransmissions by process and connection
---

# TCP Retransmit Tracker

Monitors kernel TCP retransmit events and summarizes likely network issues.

## Triggers

- "tcp retransmit"
- "network slow"
- "packet loss"
- "which process retransmits"

## What to collect

- PID + command
- Source and destination IP/port
- TCP state
- Event count over time window

## Output

- Total retransmits in duration
- Top processes by retransmits
- Top destination connections
- Suggested next action (pool size, RTT check, packet loss investigation)

## Example tool invocation

```text
ebpf_tcp_retransmit {"duration":"30s"}
```

## Notes

This skill is Linux-only. On unsupported systems (e.g. macOS) it should return a clear "not supported" result.
