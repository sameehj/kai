---
layout: post
title: Would Kai have stopped the backdoored Claude Code extension?
description: We map the October Cursor marketplace payload to Kai's actual coverage and the protection still planned.
category: Kai field notes
date: 2026-11-02 21:25:00 +0200
---

On October 29, a malicious build of the Claude Code extension appeared in the Cursor VS Code Extension Marketplace. [Cursor's incident notice](https://prod.cursor.com/blog/claude-code-extension-security-notice) says it collected host and user details, tried to add an attacker key to `authorized_keys`, attempted to enable SSH and open a reverse tunnel, and tried to persist through a LaunchAgent on macOS. Cursor also says errors in the payload meant the SSH-enabling and tunnel step would fail on most hosts without administrator privileges. That limitation belongs to the payload, not to Kai.

It is tempting to ask whether Kai would have stopped “the attack” with a single yes or no. We have not run the full payload through a measured Kai replay, so we cannot claim either outcome. We can map each attempted action to the controls that existed.

**Agent hooks:** An extension executing its own JavaScript does not invoke Claude Code's tool hook for each file write or connection. A hook-based denial of a suspicious command would help only if the extension asked the agent to run that command. The [coverage matrix](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md#enforcement-and-attribution-preview-1-configuration-a) marks editor extension hosts acting on their own as unchecked.

**Internet wall:** Preview 2 watches observed agent connections and blocks none. Development builds tested blocking for attributed agent processes, but an editor extension host may be outside that attribution, and a child that leaves the process tree can lose it. A network destination rule also cannot prevent the earlier write to `authorized_keys`.

**Files protection:** The host-wide rule we want would prevent unauthorized writes to `authorized_keys`, LaunchAgents and Kai's control store regardless of whether Kai recognized the process as an agent. More agent-aware rules could then constrain attributed sessions. This is the architecture in the [security plan](https://github.com/sameehj/kai/blob/master/docs/security/RECONCILED-PLAN.md); **it is not in Preview 2**.

The plan requires a replay using harmless fixtures from both a recognized Cursor extension host and an unrecognized VS Code extension host, including detached children. Until that record exists, the useful answer is narrower than “Kai would have stopped it”: the incident exposed why critical-file protection cannot depend on correctly naming the attacker.

*Next in the series: [Hostnames are the wrong thing to guard]({{ '/blog/hostnames-are-the-wrong-thing-to-guard/' | relative_url }}).*
