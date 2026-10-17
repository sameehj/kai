---
layout: post
title: What Kai stops today, and what still gets through
description: A measured look at the current agent hooks and the gaps they leave.
category: Field notes
---

AI coding agents can read files, run programs and send network requests with your permissions. Kai adds local checks to some of those actions, but the boundary is specific: **the current file checks run through agent hooks**.

When a supported agent announces a file read or shell command, Kai can compare the visible path or command with your policy. It can deny a protected file read, stop certain upload patterns, or flag sensitive text before it is sent through an inspected path. The audit log records a decision and reason so you can review it later.

## The measured gap

The [escape suite](https://github.com/sameehj/kai/blob/master/docs/ESCAPES.md) feeds representative actions to the hooks and records what they answer. It includes direct file reads, scripts, path construction, detached processes and network sends. Its results describe **hook behavior**, not complete protection of the Mac.

Some attempts that visibly name a protected file are stopped. A script can still build that same path at runtime, or another process can perform an action the hook never saw. That is why Kai does not call the hooks a sandbox.

## Network and storage are different boundaries

The macOS network wall can observe agent connections to destinations outside an allowlist. Its Log mode has been verified; Block mode still needs full validation. A destination rule also cannot determine whether data sent to an allowed host is safe.

The planned storage wall would use Apple Endpoint Security to check file operations as they happen, including reads from scripts. It is not built yet and requires an Apple-granted entitlement.

The useful habit today is to [review the measured results](https://github.com/sameehj/kai/blob/master/docs/ESCAPES.md), set your own protected paths, and treat Kai's decisions as one layer of control.
