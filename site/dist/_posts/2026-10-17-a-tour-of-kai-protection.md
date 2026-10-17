---
layout: post
title: A tour of Kai's protection overview
description: What the menu bar panel tells you about agent hooks, recent decisions and the network wall.
category: Feature guide
image: /assets/protection-overview.png
---

Kai lives in the macOS menu bar. Open its panel to see which integrations are configured, recent decisions, and the network wall's current mode.

<figure class="narrow">
  <img src="{{ '/assets/protection-overview.png' | relative_url }}" alt="Kai menu bar panel showing enabled Claude Code, Cursor, Codex and Chrome integrations, a network wall in Block mode, counts and recent blocked connections" width="716" height="1852" loading="eager">
  <figcaption>A development build of Kai with all four displayed integrations enabled. This is a snapshot of one Mac, not a default configuration.</figcaption>
</figure>

## Read the switches first

Each agent row reports whether Kai's integration is configured. In the screenshot, Claude Code, Cursor and Codex show hooks on. The Chrome row shows chat checking enabled. The separate network row shows that the macOS wall is on and the local policy is set to **Block**.

These labels describe configured layers. They do not mean every action from every process is covered. Agent hooks only see events the supported agent exposes. The storage wall that would authorize file operations at the operating-system level is still planned.

## What the counts mean

The three tiles summarize recent audit records: blocks this week, requests cleaned, and hosts noticed. They are counts of decisions Kai recorded, **not** a count of attacks or a measure of total agent activity. One agent retrying a blocked connection can create multiple events.

The **Recent** list shows a few decisions. Select **See all** to open Activity, where a record can show its source, rule, reason and, for newer hook records when enabled, a redacted excerpt of the attempted action. Network entries name a destination; they do not reveal the full command or prompt that caused a connection.

## Use a block to learn

If a command was blocked incorrectly, open its Activity record before changing the policy. A false-positive report can capture the rule and redacted context for review. This makes it easier to improve a narrow rule without turning off a broad protection.

For the exact scope and known bypasses, see the [escape suite](https://github.com/sameehj/kai/blob/master/docs/ESCAPES.md).
