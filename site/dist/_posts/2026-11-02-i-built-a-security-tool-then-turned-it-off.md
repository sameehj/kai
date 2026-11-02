---
layout: post
title: I built a security tool for AI agents, then turned it off to get work done
description: One WordPress price change hit three hidden gates and changed what we will ship next.
category: Kai field notes
date: 2026-11-02 21:50:00 +0200
---

On November 1, I asked Claude Code to change a price on two WordPress pages. Kai was running with its agent checks and a development build of its Internet wall set to block. Within minutes I had turned Kai off for Claude Code and switched the wall to Watch.

The task was ordinary. Claude Code needed to start a WordPress MCP server through `npx`, read the pages and edit the price. Kai turned that into a puzzle whose clues arrived in the wrong order.

First, Kai blocked the site's host. The agent called it a connection problem, which was a reasonable guess from its side: the dropped connection did not explain itself. I approved the host, more than once, while the MCP server still would not start. A previous **Keep blocked** decision on the npm registry had been remembered permanently; `npx` needed that registry. After I allowed it for an hour, Kai denied the MCP tool call and told the agent to wait for approval in Kai, then retry. The approval did not resume the call. Later, the site was blocked again despite an Allow rule because Kai could not verify the process identity that the rule required. A GitHub SSH connection added another card.

These were three different gates: a package download, an MCP tool approval and a destination rule that did not apply. To the person trying to change a price, they looked like one broken workflow. The [incident timeline](https://github.com/sameehj/kai/blob/master/docs/security/FRICTION-POSTMORTEM.md) records what Kai logged and what I actually saw.

## The failure was the decision to switch it off

Each individual rule had a rationale. The combined experience made protection unusable. The user could not tell which decision mattered, the agent could not explain the network denial, and an approval often came after the original action had failed. I turned the checks off to finish the task. We now count that as a security failure: a control disabled for normal work protects nothing.

That incident changed Preview 2. Its Internet wall ships in **Watch** mode, recording observed connections without blocking them. The hooks can still deny supported agent tool calls. Network blocking stays out of the public preview until it can handle normal developer work and pass the planned replay cases. The [release notes](https://github.com/sameehj/kai/releases/tag/v0.2.0-preview.2) state the boundary plainly.

The next design target is simple to say and hard to earn: normal work should not prompt, and a legitimate approval should let the same action continue. We will measure unexplained failures, forced reruns and protection-disable events alongside attack outcomes. The [usability plan](https://github.com/sameehj/kai/blob/master/docs/security/NEVER-RERUN.md) turns that lesson into release gates.

*Next in the series: [Fail closed, lock yourself out]({{ '/blog/fail-closed-lock-yourself-out/' | relative_url }}).*
