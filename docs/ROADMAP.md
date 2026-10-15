# Roadmap

| Phase | What ships | Needs Apple? |
|---|---|---|
| **v0.1 (now)** | Hooks for Claude Code & Cursor; policy engine; secret/company-data scanner (redact/replace/block); upload & prompt-injection detection; hash-chained audit log; `install`/`uninstall`/`scan`/`redact`/`doctor`/`log`. macOS + Linux. | No |
| **v0.2** | Local decrypting proxy for AI domains (Chrome, Cursor, desktop apps, OpenRouter) — reads & cleans prompts with no hooks. Credential proxy so agents never see raw keys. Background service (launchd/systemd). | No ($99 account only for the Network Extension variant) |
| **v0.3** | macOS Endpoint Security + Network Extension walls: file & network enforcement for every app, even through scripts. Small local judge model trained on agent attacks. | Yes (Endpoint Security entitlement) |
| **v0.4** | Linux backend (eBPF LSM + cgroup/connect, Landlock). | No |
| **v0.5** | Windows (user-mode first: restricted tokens + WFP). | No |
| **Kai Teams** | Central policy, fleet audit log, session traces, SSO, SIEM export, MDM profiles. Commercial. | No |

Gates: v0.1 → public launch; v0.2 → first design partners; v0.3 → entitlement approved; Teams → first paying team.
