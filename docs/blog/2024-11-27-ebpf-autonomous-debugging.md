---
title: "Autonomous Debugging with Custom eBPF Sensors"
date: 2024-11-27
author: KAI Team
tags: [ebpf, performance, observability, automation]
problem: "Incidents require SSH + perf tooling every time"
solution: "Codify eBPF programs as reusable KAI sensors and flows"
---

# Autonomous Debugging with Custom eBPF Sensors

Production firefights usually look like this:

1. SSH into a brittle node.
2. Compile an eBPF program from a gist.
3. Parse binary output manually.

By the time you learn the answer, the incident has already paged three teams.

KAI changes that model. We treat eBPF programs as first-class sensors and let agents reason over their output.

---

## Lock Contention as a Service

KAI ships the `ebpf.lock_contention` sensor:

- `lock_contention.bpf.c` traces `mutex_lock` enter/exit.
- Events go to a ring buffer map.
- The `ebpf` backend loads the bytecode, attaches a kprobe, and streams data for any flow step.

```yaml
- id: hot_locks
  type: sensor
  ref: ebpf.lock_contention
  with:
    duration: 15
  output:
    saveAs: mutex_events
```

The downstream agent can immediately answer:

- Which mutex is blocking the world?
- Which PID/comm combination keeps hitting that lock?
- How long are threads spinning before entry?

No SSH, no manual tooling. It runs everywhere the flow runs.

---

## DNS Visibility Without tcpdump

`ebpf.dns_tracer` answers the classic "is DNS down or slow?" question without packet captures:

- Hooks `udp_sendmsg`.
- Filters for destination port 53.
- Streams client PID, command, and destination IPs back to the runner.

Attach that to your network flows (see `flow.complete_network_debug`) and the agent gets kernel-level truth on DNS latency alongside Hubble data.

---

## Agent-Aware Binary Data

Raw ring-buffer bytes aren’t helpful. The eBPF backend wraps each event in a JSON-compatible map:

```json
{
  "timestamp": 1701028192000000000,
  "pid": 3124,
  "lock_addr": "0xffff9c0e01",
  "wait_time_ns": 1200000,
  "comm": "gunicorn"
}
```

Claude then classifies locks, calculates aggregate percentiles, and recommends mitigations. You get "Lock contention at `redis_client_mutex` - reduce concurrency or shard" instead of a blob of bytes.

---

## Rolling Out New Programs

1. Drop `<name>.bpf.c` under `recipes/sensors/ebpf/<name>/`.
2. Run `./scripts/build_ebpf.sh` to compile to `<name>.o`.
3. Author a sensor YAML referencing the bytecode path and attach type.
4. Add it to any flow.

Because sensors declare safety metadata, you can review and approve privileged probes once and reuse them everywhere.

---

## Result: 24/7 eBPF Coverage

- **Before:** Only kernel experts ran eBPF, and only while paged.
- **After:** Every runbook has repeatable kernel instrumentation, with AI summaries shipping straight to Slack.

Stop treating eBPF as a one-off hero move. Turn it into a product capability.
