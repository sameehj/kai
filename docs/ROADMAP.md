# Roadmap

| Phase | What ships | Needs Apple? |
|---|---|---|
| **v0.1 (now)** | Hooks for Claude Code & Cursor, Codex hooks (preview); policy engine; secret/company-data scanner (redact/replace/block); upload & prompt-injection detection; hash-chained audit log; `install`/`uninstall`/`scan`/`redact`/`doctor`/`log`. macOS + Linux. macOS network wall in Log mode (verified). Browser extension and gateway (experimental). Escape suite ([`ESCAPES.md`](ESCAPES.md)). | Network wall: paid developer account |
| **v0.2** | Close the gaps [security validation](SECURITY-VALIDATION.md) found (fail-closed hooks, the Terminal-control check and blocking no-hostname connections are done): network wall Block mode covers DNS, processes that leave the agent's tree, and an unreadable policy (first live run done: web traffic from the agent's own processes is blocked); a destructive-action rule. Signed, notarized Kai.app that installs on any Mac. | Developer ID + notarization |
| **v0.3** | Storage wall (Endpoint Security): open, copy, clone, link, rename and exchange events for the agent's process tree; ssh-agent socket and Keychain tool rules; protection for Kai's own files. Agent attribution that survives detached processes and tells agent-started shells from the user's own. | Yes (Endpoint Security entitlement) |
| **v0.4** | Scoped credentials: agents complete approved operations without holding reusable secrets, starting with one integration. | No |
| **v0.5** | Linux backend (eBPF LSM + cgroup/connect, Landlock). | No |
| **v0.6** | Windows (user-mode first: restricted tokens + WFP). | No |
| **Kai Teams** | Central policy, fleet audit log, MDM profiles, endpoint health, alerts. Commercial. | No |

On hold: a local decrypting (TLS man-in-the-middle) proxy. It would cover GUI chat apps, but it needs a trusted local CA, which [`WALLS.md`](WALLS.md) avoids by default; the browser extension covers browser chats instead.

Gates: v0.2 → public launch; v0.3 → entitlement approved, first design partners; Teams → first paying pilot. Every phase updates the escape suite: a new layer's rows must move from "gets through" to "stopped" in a test, not just in the docs.
