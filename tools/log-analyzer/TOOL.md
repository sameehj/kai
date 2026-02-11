---
name: log-analyzer
description: Read and analyze system and application logs — surface errors, warnings, patterns
metadata:
  kai:
    emoji: 📋
    requires:
      bins: []
    os: [linux, darwin, windows]
---

# Log Analyzer

## When to use
- "What went wrong?"
- Investigating crashes, failures, or unexpected behavior
- Checking system health after an incident
- Analyzing build output for errors

## When NOT to use
- For live process monitoring (use process-inspector)
- For network diagnostics (use network-check)

## How to use

### System logs (Linux)
- Recent errors: `journalctl -p err -n 50 --no-pager`
- Recent warnings: `journalctl -p warning -n 50 --no-pager`
- Specific service: `journalctl -u <service> -n 100 --no-pager`
- Kernel messages: `dmesg --level=err,warn | tail -50`
- Since last boot: `journalctl -b -p err --no-pager`
- Time range: `journalctl --since "1 hour ago" -p warning --no-pager`

### System logs (macOS)
- Recent errors: `log show --last 1h --predicate 'eventMessage contains "error"' | tail -50`
- System log: `cat /var/log/system.log | tail -100`

### Application logs
- Read arbitrary file: `tail -100 <path>`
- Search for errors: `grep -i -n "error\|fail\|fatal\|exception\|panic" <path> | tail -30`
- Search with context: `grep -i -B2 -A2 "error\|fail" <path> | tail -50`
- Count error types: `grep -i "error\|fail" <path> | sort | uniq -c | sort -rn | head -20`

### Build logs
- Filter errors: `grep -n "error:" <build_log>`
- Find first failure: `grep -n -m 1 "error:\|FAILED\|fatal" <build_log>`

### Windows (PowerShell)
- System errors: `Get-EventLog -LogName System -EntryType Error -Newest 20`
- Application errors: `Get-EventLog -LogName Application -EntryType Error -Newest 20`

## Output guidance
When analyzing logs, group findings by severity. Lead with the most critical errors. If you see patterns (repeated errors, cascading failures), call them out. Suggest likely root cause when possible.
