---
name: kubernetes-pod-network-debug
description: Diagnose pod-to-pod and pod-to-service network failures with CNI-aware checks.
---

# Kubernetes Pod Network Debug

## When to use

Use when users report:
- pod cannot reach service
- intermittent timeouts
- DNS works but traffic drops
- policy/CNI-related network errors

## Workflow

### 1) Basic cluster and pod health
```bash
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get svc -A | head -n 60
```

### 2) Target namespace and pod checks
```bash
kubectl -n <ns> get pod <pod> -o wide
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> exec <pod> -- ip a
kubectl -n <ns> exec <pod> -- ip route
kubectl -n <ns> exec <pod> -- cat /etc/resolv.conf
```

### 3) Connectivity tests
```bash
kubectl -n <ns> exec <pod> -- nslookup <svc>.<ns>.svc.cluster.local
kubectl -n <ns> exec <pod> -- sh -c 'curl -sv --max-time 3 http://<svc>:<port> || true'
kubectl -n <ns> exec <pod> -- sh -c 'nc -zvw2 <svc> <port> || true'
```

### 4) CNI / policy branch
Detect CNI:
```bash
kubectl -n kube-system get pods | egrep -i 'cilium|calico|flannel|weave' || true
```

NetworkPolicy:
```bash
kubectl get networkpolicy -A
kubectl -n <ns> describe networkpolicy
```

If Cilium/Hubble:
```bash
hubble status || true
hubble observe --last 50 --verdict DROPPED || true
```

### 5) Node-level clues
```bash
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=200 2>/dev/null || true
kubectl -n kube-system logs -l k8s-app=cilium --tail=200 2>/dev/null || true
```

## Output

- probable failure domain (DNS / Service / CNI / Policy / Node)
- confidence
- evidence lines
- top 3 safe remediations

## Guardrails

- No policy mutations without explicit approval.
- Prefer observation-first and reversible tests.
