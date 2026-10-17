---
layout: post
title: Understanding Kai's network wall
description: How Log, Block and Off work, and how to read the destination list.
category: Feature guide
image: /assets/network-wall.png
---

The network wall helps you see where recognized AI agents connect. On macOS it uses a Network Extension to inspect outbound flows from agent processes and apply your destination policy. Other apps are outside Kai's intended scope.

<figure>
  <img src="{{ '/assets/network-wall.png' | relative_url }}" alt="Kai Network settings showing the wall on, Block selected, and a list of hosts reached by recognized agents with counts and Allow buttons" width="1954" height="1092" loading="eager">
  <figcaption>Kai's Network settings in a development build. The list contains destinations recorded on this Mac; it is not a list of recommended hosts to allow.</figcaption>
</figure>

## Choose a mode

**Log only** lets a connection proceed and records destinations outside the allowlist. It is useful for learning what an agent reaches before changing policy.

**Block** asks the wall to drop a recognized agent's connection when its destination is outside the allowlist. The screenshot shows this mode selected. The UI's green **On** badge means the wall is enabled; the selected card controls its behavior.

**Off** pauses the wall. Agent hook checks are a separate layer, so this setting does not describe their state.

## Read the destination table

Each row shows a destination, the recognized agent or agents, and how many recorded events involved it. A high count can mean repeated attempts by one app, not many distinct incidents. The **Allow** button adds a hostname to your policy; review the destination before using it. Some rows show only an IP address and port because Kai could not recover a hostname, and those cannot be safely added as named-host exceptions from this view.

The screenshot includes connections associated with Cursor, Claude Code and Codex. The listed hostnames are examples of what this particular Mac recorded. Their presence alone does not establish that a connection was malicious.

## What this does not prove

The wall is not a full history of all network traffic. Allowed destinations are generally passed without an audit entry, and only recognized agent process trees are in scope. Some traffic without a readable hostname, including certain non-web connections, is not blocked today. A process that detaches from the agent's parent tree can lose that attribution. An allowlist also cannot tell whether sending data to an allowed service is appropriate.

Kai's [wall design](https://github.com/sameehj/kai/blob/master/docs/WALLS.md) and [threat model](https://github.com/sameehj/kai/blob/master/docs/THREAT_MODEL.md) describe the current boundary and planned improvements.
