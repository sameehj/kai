---
title: "Debugging Kubernetes Network Issues in 30 Seconds with Hubble + Claude"
date: 2024-11-26
author: KAI Team
tags: [kubernetes, networking, hubble, ebpf, cilium]
problem: "Pod can't reach service - is it CNI, iptables, DNS, or network policy?"
solution: "Hubble observability + Claude correlation"
---

# Debugging Kubernetes Network Issues in 30 Seconds

## The Problem (From r/kubernetes)

> "Pod can't talk to service. Spent 2 hours checking:
> - iptables rules (30 minutes)
> - Network policies (45 minutes)
> - DNS resolution (30 minutes)
> - Conntrack table (15 minutes)
>
> Still no clue what's wrong."

**Sound familiar?**

---

## Why Network Debugging is Hell

Kubernetes networking has **7 layers of abstraction**:

1. **Pod network** (CNI plugin)
2. **Service** (kube-proxy / eBPF)
3. **Network policies** (Calico / Cilium)
4. **DNS** (CoreDNS)
5. **Conntrack** (kernel state tracking)
6. **iptables** (NAT rules)
7. **Physical network** (switches, firewalls)

**Traditional approach:** Check each layer manually (2+ hours).

---

## The KAI Solution
```bash
kai run-flow flow.k8s_network_debug \
  --pod api-server-abc123 \
  --namespace production
```

**30 seconds later:**
```
🔍 Network Debug Complete

Root Cause: Network policy blocking egress to 10.96.0.0/12
Affected Component: NetworkPolicy "strict-egress"
Confidence: 94%

Evidence:
- Hubble: 847 packets dropped (verdict: POLICY_DENIED)
- All drops match policy rule #3
- TCP: 156 SYN retries, 0 successful connections
- DNS: Working fine (ruled out)
- Conntrack: SYN packets with no state entries

Recommendation: Add service CIDR to egress whitelist

Fix:
kubectl patch networkpolicy strict-egress -n production \
  --type=json -p='[{"op":"add","path":"/spec/egress/-",
  "value":{"to":[{"ipBlock":{"cidr":"10.96.0.0/12"}}]}}]'
```

---

## How It Works

### Step 1: Hubble Captures Network Flows (eBPF)
```bash
# Hubble observes every packet at the kernel level
hubble observe --pod api-server-abc123 --last 1000
```

**What Hubble sees:**
```
TCP 10.244.1.5:45678 -> 10.96.0.1:443 policy-verdict:DENIED
TCP 10.244.1.5:45679 -> 10.96.0.1:443 policy-verdict:DENIED
TCP 10.244.1.5:45680 -> 10.96.0.1:443 policy-verdict:DENIED
... (847 more drops)
```

---

### Step 2: Check Conntrack State
```bash
cat /proc/sys/net/netfilter/nf_conntrack_count
# Shows: 0 established connections
```

**Translation:** SYN packets sent but no connections established = traffic blocked before reaching destination.

---

### Step 3: Verify DNS
```bash
nslookup kubernetes.default.svc.cluster.local
# Works fine → DNS not the issue
```

---

### Step 4: Claude Correlates Everything
```
Input to Claude:
- 847 dropped packets (all to 10.96.0.0/12)
- All drops have verdict: POLICY_DENIED
- 0 conntrack entries
- DNS resolution works
- All drops match network policy "strict-egress" rule #3

Output from Claude:
Root Cause: Network policy blocking service CIDR
Confidence: 94% (high because all evidence points to same policy)
Fix: Whitelist 10.96.0.0/12 in egress rules
```

---

## Why This is 100x Faster

**Traditional debugging:**
```
1. Check pod logs (5 min)
2. Check service endpoints (5 min)
3. Dump iptables rules (10 min)
4. Parse iptables output (15 min)
5. Check network policies (20 min)
6. Test DNS manually (5 min)
7. Check conntrack (5 min)
8. Correlate findings (30 min)
Total: ~2 hours
```

**KAI debugging:**
```
1. Run flow (30 seconds)
Total: 30 seconds
```

---

## Real Production Example

**Symptom:** Frontend can't reach backend API

**KAI Output:**
```
Root Cause: DNS timeout after 5 seconds
Affected: CoreDNS pod restarting every 30s
Evidence:
- Hubble: DNS queries to 10.96.0.10:53 timeout
- Conntrack: Connection attempts with no replies
- DNS pod logs: OOMKilled (memory limit 64Mi)
Recommendation: Increase CoreDNS memory to 256Mi
Confidence: 97%
```

**Fix applied:** 1 line change in CoreDNS deployment.
**Time saved:** 1-2 hours of debugging.

---

## Installation

### Prerequisites
```bash
# Requires Cilium with Hubble enabled
helm install cilium cilium/cilium \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

### Run KAI Flow
```bash
# Install KAI
curl -fsSL https://get.kai.sh | sh

# Debug network issue
kai run-flow flow.k8s_network_debug \
  --pod  \
  --namespace
```

---

## Under the Hood

### The Flow Definition
```yaml
steps:
  - id: hubble_flows
    type: sensor
    ref: hubble.capture_flows
    # Uses Hubble API to get last 1000 flows

  - id: tcp_stats
    type: sensor
    ref: net.tcp_stats
    # Gets TCP retransmit stats

  - id: conntrack
    type: sensor
    ref: net.conntrack_usage
    # Checks connection tracking table

  - id: diagnose
    type: agent
    agentType: correlation
    # Claude analyzes all data sources
```

---

## Common Issues Detected

1. **Network Policy Misconfig** (most common)
2. **CoreDNS Issues** (memory limits, crashes)
3. **Service Endpoint Mismatch**
4. **Conntrack Table Full**
5. **MTU Problems**
6. **CNI Plugin Issues**

---

## Conclusion

Network debugging doesn't have to take hours.

**With KAI:**
- ✅ Automatic data collection (Hubble + system tools)
- ✅ AI correlation across data sources
- ✅ Actionable recommendations
- ✅ 30-second diagnosis

**Try it:** [Install KAI](https://github.com/sameehj/kai)

---

*Based on debugging hundreds of network issues in production Kubernetes clusters.*
