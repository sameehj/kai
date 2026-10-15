# Server Audit

Goal: produce a concise machine audit with evidence.

## 1. Overview

- `exec: "hostname && uname -a && uptime"`
- `exec: "free -h && df -h"`

## 2. Processes and services

- `exec: "ps aux --sort=-%cpu | head -20"`
- `exec: "systemctl list-units --type=service --state=running --no-pager | head -80"`

## 3. Network exposure

- `exec: "ss -lntup"`
- Map listening ports to owning processes and expected services.

## 4. Users and access

- `read: "/etc/passwd"`
- `exec: "last -n 20"`
- `exec: "sudo -l -U <user>"` when explicitly requested
- `read: "~/.ssh/authorized_keys"` for relevant accounts

## 5. Scheduled tasks

- `exec: "crontab -l || true"`
- `exec: "ls -la /etc/cron*"`

## 6. Firewall and containers

- `exec: "iptables -S || nft list ruleset || ufw status"`
- `exec: "docker ps --format '{{.Names}} {{.Image}} {{.Status}}' || true"`

## 7. Security-relevant findings

Highlight:
- unexpected public listeners
- stale privileged accounts
- failed login bursts
- disk-full risk
- outdated kernel/packages when visible

## 8. Output format

- Overview
- Users/Access
- Network/Services
- Storage/Jobs
- Security Findings
- Recommended actions by risk order
