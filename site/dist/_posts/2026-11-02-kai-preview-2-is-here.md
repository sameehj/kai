---
layout: post
title: Kai 0.2.0 Preview 2 is here
description: A signed, notarized macOS preview that checks supported agent actions and shows where agents connect.
category: Release notes
---

**Kai 0.2.0 Preview 2 is available for macOS 13 and later.** The installer is signed and notarized. Kai checks what your agents do, and shows you where they connect.

This preview has two parts. Inside Claude Code, Codex and Cursor, Kai checks the actions those agents send to its hooks. If a supported tool call tries to read a protected file or send sensitive data, Kai can stop it before the tool runs. The message explains the decision and how you can allow a legitimate action narrowly.

The Kai app also has an Internet wall. In Preview 2 it runs in **Watch** mode: it records the connections it observes, including the destination and agent, but **does not block connections**. You can use that view to see where an agent goes while it works.

## What the preview cannot cover

Agent checks only see actions an agent reports to them. A script the agent writes and runs can read files or make HTTPS connections outside those checks. Preview 2 has no operating-system Files protection or browser chat coverage. It does not inspect encrypted request contents or stop data leaving through an allowed service such as GitHub or npm. The Internet wall's Watch mode is visibility, not a network deny rule.

We are publishing these limits alongside the release so you can decide where Kai is useful today. The full end-to-end replay of attack cases is still outstanding. The [coverage guide](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md) describes the supported actions and evidence in detail.

## Get started

1. Download the `.pkg` from the [Preview 2 release](https://github.com/sameehj/kai/releases/tag/v0.2.0-preview.2) and double-click it.
2. Open Kai, switch **Internet** on in its menu bar panel, and approve the network extension when macOS asks. On macOS 13–14, look in **System Settings → Privacy & Security**. On macOS 15, look in **General → Login Items & Extensions → Network Extensions**.
3. In your own Terminal, run `kai install claude` (or `kai install codex` or `kai install cursor`), then `kai doctor` to check the setup. For Codex, open `/hooks` in Codex and trust Kai's hooks.

You can optionally verify the package with the checksum and `spctl` commands in the [README](https://github.com/sameehj/kai#verify-the-download), which also has uninstall steps. The [release notes](https://github.com/sameehj/kai/releases/tag/v0.2.0-preview.2) include the verification details and known issues.
