---
title: "Tetragon-Powered Security Investigations in Minutes"
date: 2024-11-27
author: KAI Team
tags: [tetragon, security, ebpf]
problem: "Security team lacks syscall-level evidence when alerts fire"
solution: "Stream Tetragon events into KAI flows and auto-summarize findings"
---

# Tetragon-Powered Security Investigations in Minutes

Tetragon already collects the gold-standard telemetry for Linux security, but analysts rarely have time to sift through raw JSON. KAI uses a lightweight (v0.1, read-only) backend that shells out to `tetra getevents`, parses each line, and exposes the structured data to any flow.

Paired with the `flow.security_forensics` recipe, you can answer:

- Which binaries executed around the alert window?
- Were any network pivots attempted from that pod?
- Did processes exit normally or crash mid-flight?

Claude receives the full event list (capped at 100 entries for brevity) and returns a human summary with root cause, confidence, and recommended containment steps. It’s the SOC note you wish every responder wrote.
