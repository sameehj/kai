---
layout: post
title: Fail closed, lock yourself out
description: Three hook failures taught us to protect tool calls without trapping the person using the agent.
category: Kai field notes
date: 2026-11-02 21:40:00 +0200
---

“Fail closed” sounds like the obvious rule for a security hook. If Kai cannot check an action, the action should not run. During development, we learned how easily that rule can turn into a locked door with the developer on the wrong side.

We hit three failures in one day. A development binary was deleted while an agent's hook still pointed at it. A hook command used an unquoted path containing a space. A shell wrapper returned `exit 2` for every hook event when Kai failed. The first two broke the program the hook was supposed to call; the last one made the failure propagate much further than intended. In Claude Code, blocking every prompt or lifecycle event can leave a user unable to use the agent to recover.

Those failures exposed two different questions. Should an unchecked **tool call** proceed? Usually no: it might be a file read or an upload. Should the user be prevented from **sending a prompt or ending the session** because Kai is broken? No. A person needs a path back to control.

## Separate the event types

Preview 2 now gives Claude Code tool hooks `onFailure: "block"`. Its packaged launcher provides a stable executable path, and Kai's health checks can identify a missing program and point to Repair. The guard belongs on tool-use events. Prompt and lifecycle hooks are not guarded the same way, so a broken Kai does not make every prompt fail or trap the agent at Stop. Codex and Cursor use their own hook mechanisms with the same recovery goal. The [implementation](https://github.com/sameehj/kai/blob/master/src/install.c) and [Preview 2 release notes](https://github.com/sameehj/kai/blob/master/docs/release/0.2.0-preview.2.md) record the change and the previous-build test.

This does not mean a missing Kai silently becomes safe. The agent's tool action is denied, and the message should say that Kai needs repair and how to remove its hooks if necessary. The user can still communicate, diagnose and choose the recovery path. That is a different failure mode from refusing every interaction.

The design rule we kept is precise: **when the security system fails, stop the risky operation and preserve the user's ability to regain control.** The release test deleted Kai's program on purpose and checked that prompts still went through while tool calls were denied. We will keep testing that boundary whenever an agent changes its hook behavior.

*Next in the series: [The honest agent problem]({{ '/blog/the-honest-agent-problem/' | relative_url }}).*
