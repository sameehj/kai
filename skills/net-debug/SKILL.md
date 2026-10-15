# Network Debug

Use for packet loss, retransmissions, DNS problems, high latency, and connection
failures.

## Steps
1. Baseline: `ss -s`, `ip addr`, `ip route`
2. Counters: `cat /proc/net/snmp`, compare deltas if needed
3. Logs: `dmesg --time-format iso | tail -100`
4. Optional tracing (confirm first): tcp retransmit bpftrace one-liner

## Report
Include impacted destination(s), retransmit/error indicators, and clear next actions.
