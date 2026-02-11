---
name: network-check
description: Diagnose network connectivity — DNS, ports, TCP state, latency
metadata:
  kai:
    emoji: 🌐
    requires:
      bins: []
    os: [linux, darwin, windows]
---

# Network Check

## When to use
- "Why can't I connect to X?"
- Diagnosing DNS, firewall, or connectivity issues
- Checking if a service is reachable
- Investigating slow network performance

## When NOT to use
- For deep packet inspection (suggest tcpdump or Wireshark)
- For eBPF-level tracing (suggest ebpf-inspector from KaiHub)

## How to use

### DNS resolution
- Linux/macOS: `nslookup <hostname>` or `dig <hostname> +short`
- Check /etc/resolv.conf: `cat /etc/resolv.conf`

### Port checks
- Is port open: `nc -zv <host> <port> 2>&1` (timeout with `-w 3`)
- Listening ports: `ss -tlnp` (Linux) or `lsof -iTCP -sTCP:LISTEN` (macOS)

### TCP connection state
- All connections: `ss -tnp` (Linux) or `netstat -an | grep ESTABLISHED` (macOS)
- Connection counts by state: `ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn`
- Connections to specific host: `ss -tnp dst <ip>`

### Latency
- Ping: `ping -c 5 <host>`
- Traceroute: `traceroute -m 15 <host>` or `traceroute -I <host>`
- HTTP timing: `curl -o /dev/null -s -w "dns: %{time_namelookup}s\nconnect: %{time_connect}s\nttfb: %{time_starttransfer}s\ntotal: %{time_total}s\n" <url>`

### Retransmits and errors
- Linux: `nstat -az | grep -i retrans`
- Interface errors: `ip -s link show`

### Firewall
- Linux (iptables): `iptables -L -n --line-numbers 2>/dev/null || echo "Need root"`
- Linux (nftables): `nft list ruleset 2>/dev/null || echo "Need root"`
- macOS: `pfctl -sr 2>/dev/null`

### Windows (PowerShell)
- DNS: `Resolve-DnsName <hostname>`
- Port: `Test-NetConnection -ComputerName <host> -Port <port>`
- Connections: `Get-NetTCPConnection | Where-Object State -eq Established`

## Output guidance
Start with the simplest check (DNS, then connectivity, then latency). Only dig deeper if the basic checks reveal issues. Report findings in order of likely root cause.
