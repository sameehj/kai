---
layout: post
title: When an AI agent asks to control Terminal
description: A macOS Automation prompt raised a question about agent hooks, process boundaries, and what we can actually prove.
category: Field notes
---

While building Kai, macOS showed a permission prompt: **“claude.exe wants access to control Terminal.”** It was surprising. A name ending in `.exe` looks out of place on a Mac, and giving a coding agent control of Terminal is a consequential decision.

The prompt did **not** prove that Claude Code was trying to evade Kai. We could not establish which action triggered it. We also have not demonstrated that Terminal Automation bypasses Kai. Those distinctions matter when reporting a security finding.

## What we could verify

The `claude.exe` name alone is not evidence of malware. An [issue in Anthropic's Claude Code repository](https://github.com/anthropics/claude-code/issues/64197) documents a native macOS Claude Code binary with that name. On our machine, the executable was inside the installed Claude Code package. That verifies the binary's location, not why this particular permission request appeared.

Apple's [Automation permission](https://support.apple.com/en-nz/guide/mac-help/mchl108e1718/mac) lets one app control another. The decision belongs to the person using the Mac. If you did not intend to let an agent control Terminal, choose **Don't Allow**. You can review the setting later in **System Settings → Privacy & Security → Automation**.

## Why the prompt matters to Kai

Kai's agent hooks inspect supported tool calls before they run. They can stop a visible command that asks Terminal to execute something. But hooks only see actions that pass through those tool events. A program launched by an agent can construct an action at runtime that the hook never saw in the original command.

There is another boundary at the network wall. Kai identifies agent traffic by process attribution. If an independently running Terminal executes a command on an agent's behalf, we need to measure whether that traffic is still attributed to the protected agent. A connection from Terminal could be treated differently from a connection made by the agent's own process. **That is a testable possibility, not a confirmed bypass.**

Our [escape suite](https://github.com/sameehj/kai/blob/master/docs/ESCAPES.md) records what the hooks answer for representative commands. It does not, by itself, prove what happens after a real macOS Automation grant. A hook decision and an operating system outcome are different kinds of evidence.

## The test we need

First, document exactly how the network wall identifies a protected process. Then, only on a Mac where Terminal Automation is **already** permitted, compare a harmless request to a controlled endpoint through the agent's normal shell tool with the same request through Terminal Automation. Record the process attribution, the hook decision, the network decision, and the audit entry for each path. Do not read secrets, request a new permission, or weaken the policy for this test.

Until that comparison is run, the honest verdict is **unconfirmed**. The prompt gave us a concrete scenario to investigate, and it shows why we publish Kai's measured limits: a security product should say what it observed, what it stopped, and what remains unknown.
