# Standalone eBPF Demo Recipes

These recipes showcase how KAI pairs production-ready eBPF tooling with Claude analysis for unforgettable demos. Each sensor shells out to the standard BCC tools (`tcpconnect-bpfcc`, `opensnoop-bpfcc`, `execsnoop-bpfcc`) so they work on any modern Ubuntu system.

## Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y bpfcc-tools linux-headers-$(uname -r) linux-tools-$(uname -r)
sudo tcpconnect-bpfcc --help
```

## Sensors

| Sensor ID           | Tool                | Description                              |
|---------------------|---------------------|------------------------------------------|
| `ebpf.tcp_tracer`   | `tcpconnect-bpfcc`  | Streams every TCP connection in real time |
| `ebpf.file_tracer`  | `opensnoop-bpfcc`   | Shows file open activity                  |
| `ebpf.exec_tracer`  | `execsnoop-bpfcc`   | Captures every `execve()` invocation      |

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
ANTHROPIC_API_KEY="sk-ant-..." ./bin/kaictl run-flow flow.live_network_tracer
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
ANTHROPIC_API_KEY="sk-ant-..." ./bin/kaictl run-flow flow.security_monitor
```

Claude reports sensitive file access, risk rating, and recommendations.

### Process Monitor

```bash
ANTHROPIC_API_KEY="sk-ant-..." ./bin/kaictl run-flow flow.process_monitor
```

Claude highlights automation, suspicious commands, and overall workload footprint drawn from `execsnoop` output.

## Hackathon Script

1. Intro slide: “Traditional monitoring lies.”
2. Demo 1: run `flow.live_network_tracer`. Show raw eBPF output + Claude analysis.
3. Demo 2: run `flow.security_monitor`. Trigger `/etc/shadow` read to prove visibility.
4. Demo 3: run `flow.process_monitor`. Emphasize “kernel telemetry + AI = instant narratives.”

Wrap with the architecture diagram (eBPF → KAI Engine → Claude → Actions) and call out that everything is open source.
