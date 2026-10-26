---
layout: post
title: What does “allow this MCP tool” actually mean?
description: A host, a server instance and a tool call are different permissions, with different enforcement points.
category: Engineering notes
---

Suppose an agent needs to update a page through an MCP server. A network log may show a connection to the server's host. That is useful, but the decision the user cares about is often narrower: **may this agent session call this server's `update_page` tool?**

A host grant, a server grant and a tool grant answer different questions. A host grant permits a connection to a destination. It does not confine the agent to one tool, one page or one kind of data. A tool decision made by a hook can inspect the call, but it cannot govern a direct API request that never passes through that hook.

## What Kai sees today

Kai installs supported Claude Code and Cursor MCP-related hooks. Those hooks scan tool arguments for recognized secrets or blocked terms and can deny a matching call. Kai's network wall can separately decide on a connection from an attributed process. This does **not** amount to a per-server, per-tool allow/ask/block policy. Kai does not yet bind a tool permission to a particular configured server instance and agent session, or prove that every MCP call format is visible to its hooks. A remote MCP service also does not inherit the local process tree's network restrictions.

## A useful permission has to name its subject

An approval should identify the agent session, the configured server instance, the tool name and the operation being attempted. The server's display name is only a label. If its executable, endpoint or relevant configuration changes, the old approval should not silently apply to the replacement. Arguments can provide useful context, but Activity and notifications must redact secrets before storing or displaying them.

The [MCP tools specification](https://modelcontextprotocol.io/specification/2026-07-28/server/tools) describes tool calls and says clients must treat tool annotations as untrusted unless they come from trusted servers. A server's “read-only” annotation is therefore a claim to show the user, not proof that a call cannot change data.

For a task needing both a tool and a new host, one decision card could present two separate permissions: “call `wordpress.update_page` in this session” and “connect to `example.org:443` in this session.” The user could approve one, both or neither. Adding an endpoint to `.mcp.json` would create a review item, not a grant.

## Where this design can fail

Tool names may collide across servers. Hook payloads can change. A shared MCP server process may serve two agent sessions while the network wall sees only one process. A host allowed for a legitimate tool can also receive a direct request that bypasses tool-level checks. These are boundaries the UI must state, rather than summarizing them as “MCP protected.”

The test is a pair of concurrent sessions: approve a named tool and host for session A, use them from A, then attempt the same calls from B and through a direct request. Record the hook event, process attribution, wall decision and audit entry for each path. Until that replay passes, per-tool session approval remains a **design target**, while Kai's current MCP argument scanning is the narrower implemented feature.
