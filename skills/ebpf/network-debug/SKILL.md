---
name: ebpf-network-debug
description: End-to-end Linux network drop and retransmit diagnostics using standard CLI tools with optional eBPF deep dive.
---

# eBPF Network Debug (Killer Skill v1)

## When to use

Use when user reports:
- packet drops
- retransmits / slow TCP
- intermittent connection failures
- Kubernetes service-to-service network issues

## Triggers

- "network drops"
- "tcp retransmit"
- "packet loss"
- "slow network"
- "k8s traffic failing"

## Safety + scope

- Prefer read-only diagnostics first.
- Avoid changing firewall/network policy automatically.
- If requiring root or capabilities, ask before privileged commands.

## Workflow (fast-to-deep)

### 1) Baseline host + kernel
Run:

```bash
uname -a
cat /etc/os-release
ip -br a
ip -s link
ss -s
netstat -s 2>/dev/null | egrep -i 'retrans|drop|fail|reset' || true
```

Interpretation:
- rising RX/TX drops on interfaces => NIC/queue/driver pressure
- high TCP retrans segments => path loss/congestion/peer slowness

### 2) Port/process focus
Run:

```bash
ss -ti state established | head -n 80
sudo ss -tulpn | head -n 80
```

Look for:
- repeated retrans/backoff in `ss -ti`
- specific process/socket concentration

### 3) Kubernetes branch (if kubectl exists)

```bash
kubectl get nodes -o wide
kubectl get pods -A | head -n 60
kubectl -n kube-system get pods | egrep -i 'cilium|calico|flannel' || true
```

If Cilium/Hubble present:

```bash
hubble status || true
hubble observe --last 50 --verdict DROPPED || true
```

### 4) eBPF deep dive (Linux + capability only)
Pre-check:

```bash
test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING
mount | grep '/sys/fs/bpf' || echo BPF_FS_MISSING
```

Optional trace (if available in environment):

```bash
sudo timeout 20s bpftrace -e 'tracepoint:tcp:tcp_retransmit_skb { @[comm] = count(); }'
```

Fallback if bpftrace unavailable:

```bash
sudo timeout 20s perf trace -e tcp:tcp_retransmit_skb 2>/dev/null | head -n 40
```

### 5) Report template
Return concise output:
1. probable root cause
2. confidence level (high/medium/low)
3. evidence bullets (command + key line)
4. next 3 actions (safe, ordered)

## Example final diagnosis style

- **Likely issue:** CNI policy drop on egress 443 (medium confidence)
- **Evidence:** `hubble observe` shows DROPPED flow to api.example.com:443; retransmits elevated in `netstat -s`
- **Next actions:**
  1) verify NetworkPolicy egress allowlist for destination
  2) test temporary allow rule in staging
  3) re-run retransmit trace for 5m and compare baseline

## Notes for macOS controller mode

If running on macOS, use SSH to Linux target and execute the same workflow remotely. Keep local commands limited to connectivity checks and orchestration.
