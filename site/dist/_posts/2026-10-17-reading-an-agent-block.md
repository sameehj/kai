---
layout: post
title: Reading an agent block
description: How to tell which Kai layer made a decision and investigate a false positive.
category: Product notes
---

When Kai says an action was blocked, the useful next question is: **which layer made the decision, and why?** A hook block and a network block happen at different points.

An agent hook checks a tool call before the tool runs. It can return a denial with a rule and short reason. The network wall checks an outbound connection from a recognized agent process. A network decision names a destination; it does not contain the whole command that led to it.

## What to look for

Open Kai's Activity page or use `kai log show` in a terminal. Find the agent, action type, rule and verdict. Current development builds can keep a short, redacted excerpt of a blocked command, path or prompt when **Show what was blocked** is enabled. Older records cannot gain excerpts later.

If an ordinary action was blocked, report it as a false positive with the rule and context. Kai has a local `kai report` command for this; it writes a file for you to review before you choose to open a GitHub issue. A narrow exception may be appropriate for a specific command, but weakening a broad rule to hide one false alarm makes later decisions harder to trust.

Kai keeps the audit log local. Redaction removes detected secrets from excerpts, but detectors can miss things, so you can switch excerpt storage off and keep only the rule and reason.
