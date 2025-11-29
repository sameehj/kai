# Standalone eBPF Demo Recipes

These recipes showcase how KAI combines prebuilt **CO-RE eBPF** programs with Claude analysis for compelling demos. The sensors in `recipes/sensors/ebpf/` ship as `.bpf.c` + `.o` pairs, load through the eBPF backend, and work anywhere with Linux 5.8+ and BTF.

## Prerequisites

```bash
sudo -E ./scripts/check_ebpf_env.sh   # optional helper when available
which bpftool || sudo apt install -y bpftool
sudo mount bpffs /sys/fs/bpf || true
```

## Sensors

| Sensor ID           | Description                                            |
|---------------------|--------------------------------------------------------|
| `ebpf.tcp_tracer`   | Hooks TCP connect/accept and streams tuple metadata    |
| `ebpf.dns_tracer`   | Observes UDP/53 traffic, latency, and failing lookups  |
| `ebpf.lock_contention` | Captures mutex wait time to surface hot locks    |

## Flows

| Flow ID                    | Purpose                                           |
|----------------------------|---------------------------------------------------|
| `flow.live_network_tracer` | Trace TCP + collect stats, then AI analysis       |
| `flow.security_monitor`    | Monitor file access and score security risk       |
| `flow.process_monitor`     | Summarize all process executions                  |

### Example: Live Network Tracer

Terminal 1 (traffic):

```bash
curl https://google.com &
curl https://github.com &
ssh localhost &
```

Terminal 2 (run the flow):

```bash
sudo -E ANTHROPIC_API_KEY="sk-ant-..." ./bin/kaictl run flow.live_network_tracer
```

Expected output includes raw tcp trace data followed by Claude’s summary (process mix, destinations, success rate, anomalies).

### Security Monitor

Trigger file activity:

```bash
cat /etc/passwd
ls ~/.ssh/
sudo cat /etc/shadow
```

Run the flow:

```bash
sudo -E ANTHROPIC_API_KEY="sk-ant-..." ./bin/kaictl run flow.security_monitor
```

Claude reports sensitive file access, risk rating, and recommendations.

### Process Monitor

```bash
sudo -E ANTHROPIC_API_KEY="sk-ant-..." ./bin/kaictl run flow.process_monitor
```

Claude highlights automation, suspicious commands, and overall workload footprint drawn from `execsnoop` output.

## Hackathon Script

1. Intro slide: “Traditional monitoring lies.”
2. Demo 1: run `flow.live_network_tracer`. Show raw eBPF output + Claude analysis.
3. Demo 2: run `flow.security_monitor`. Trigger `/etc/shadow` read to prove visibility.
4. Demo 3: run `flow.process_monitor`. Emphasize “kernel telemetry + AI = instant narratives.”

Wrap with the architecture diagram (eBPF → KAI Engine → Claude → Actions) and call out that everything is open source.
