---
layout: post
title: Five ways an agent can walk around agent hooks
description: Our audit found path tricks, scripts, detached children and editor processes that hooks alone cannot contain.
category: Kai field notes
date: 2026-11-02 21:30:00 +0200
---

Hooks are useful because they run before a supported agent tool call. Kai can see a file path, command or MCP request and return a denial before that call runs. We tried to break that promise in our own escape suite. Some gaps were parser bugs we could fix. Others are outside what hooks can see at all.

**1. Change the case of a path.** On a typical macOS volume, a differently capitalized spelling can refer to the same file. An early protected-path check missed that variant. Kai's current hooks compare protected paths without letter case; the [coverage matrix](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md) records a synthetic stop. That fixes this spelling trick in the checked tool call, not every way to reach the file.

**2. Move the containing folder.** A command can rename a directory and then reach a protected child through its new location. The audit also tested relative paths after changing directories. Kai now checks the relevant move, copy, archive and delete commands it can parse. The same operation inside a script remains outside the hook's view.

**3. Write a script, then run it.** The hook may see `python3 read.py`, but not the file that script opens at runtime. In a [live Claude Code coverage run](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md#live-check-claude-code-21312-on-a-real-session-2026-10-28), the direct read was denied and a Python script reading the same fixture succeeded. More shell patterns will not close a boundary that exists inside another process.

**4. Let a child outlive its parent.** The agent's hook runs before the command that starts a process. Once the child is detached, later file and network actions have no hook event. In one live network-wall test, a backgrounded request whose parent exited got through without a wall record. That is an attribution problem as well as a hook limit; the [validation record](https://github.com/sameehj/kai/blob/master/docs/SECURITY-VALIDATION.md) calls it out.

**5. Run code in the editor's extension host.** A malicious extension can execute as part of an editor without asking the coding agent to use a tool. Kai's agent hooks do not receive that operation. The [security plan](https://github.com/sameehj/kai/blob/master/docs/security/RECONCILED-PLAN.md) therefore tests both recognized and unrecognized extension hosts.

The first two cases improved Kai's hook parser. The last three need a different boundary. Preventive file checks at the operating-system level and reliable process attribution are part of the plan, not Preview 2. Today, the honest description is **agent checks for supported tool calls**, with the bypasses published beside them.

*Next in the series: [Would Kai have stopped the backdoored extension?]({{ '/blog/would-kai-stop-the-backdoored-extension/' | relative_url }}).*
