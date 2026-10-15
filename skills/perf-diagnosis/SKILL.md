# Performance Diagnosis

Use this playbook when the user reports slowness, latency, high load, CPU spikes,
or degraded throughput.

## Phase 1: Triage
1. `exec` command: `uptime && free -h && df -h / && uname -r`
2. `exec` command: `dmesg --time-format iso | tail -100`
3. `exec` command: `last -n 5 reboot`

## Phase 2: Identify bottleneck
- CPU: `mpstat -P ALL 1 3`, `pidstat -u 1 3`
- IO: `iostat -xz 1 3`
- Network: `ss -s`, `/proc/net/snmp`
- Memory: `vmstat 1 5`, `/proc/meminfo`

If bpftrace exists and policy allows sudo, request confirmation then run short eBPF
samples.

## Output format
- Summary
- Evidence
- Timeline
- Recommendations (low risk first)
