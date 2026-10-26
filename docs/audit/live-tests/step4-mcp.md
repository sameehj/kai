# v1 Step 4 — MCP-aware policy (inside the existing hooks)

No MCP proxy. Kai decides MCP tool calls from what the hooks already see.

## Identity (src/policy.c)
- `kai_mcp_parse_tool("mcp__<server>__<tool>")` → (server, tool). The tool part
  may contain `__`. A name that isn't this shape returns 0 and is treated as a
  normal tool call ("unknown" → ordinary decision).

## Policy grammar (src/policy.c parse)
- One new directive: `mcp <server> <tool|*> allow|ask|block`.
- `kai_mcp_decide(policy, server, tool)` — most-specific match wins (exact
  server+tool, then server+`*`, then `*`+`*`); **no rule = ask**. Server
  descriptions and annotations (`readOnlyHint`, …) are never read here and never
  change the decision.

## Hook decision (src/hooks.c, Claude PreToolUse)
- An `mcp__…` tool is decided by the `mcp` policy, before file/command rules.
  allow → runs; block → deny; ask → fail closed with a one-time "allow this
  time?" card (deny if the agent can't prompt).
- The card/audit reason is `MCP · <server> · <tool> — args: <keys>` — argument
  **keys only**; libkai redacts values. No URL, no argument values.

## Unit tests (tests/storage/run_storage_tests.c → test_mcp_policy) — PASS (11)
  - parse mcp__server__tool; tool may contain `__`; a normal tool isn't MCP;
    malformed name not parsed
  - exact server+tool rule wins (block); server `*` allows other tools; explicit
    `ask`; unseen server defaults to ask; global `*` allow; exact beats global

## Live hook smoke test (this run, kai-test + sandbox home) — PASS
  policy: `mcp github create_issue block` / `mcp github * allow`
  - `mcp__github__create_issue` → `deny` "Blocked by Kai: MCP · github ·
    create_issue — args: title, body"
  - `mcp__github__list_repos` → allow (no hook output, proceeds)
  - `mcp__weather__forecast` (unseen) → `ask` "Kai: MCP · weather · forecast —
    args: city. Allow it this time?"

## Done / not-done
- **Done:** identity parsing, policy grammar + decision, hook enforcement +
  display, annotations never decide, agent-added server grants nothing until
  approved (default ask).
- **Follow-on (needs the app card + approval store, or live agents):**
  - *Approving creates a persistent Kai session grant.* Today the Claude hook's
    "ask → allow" is Claude Code's own one-time allow; persisting it as a Kai
    session grant needs the approval-store/card flow (ties into Step 3's single
    write path). Flagged.
  - *Network-wall link:* offering the server's declared host as a second grant
    on the same card. Needs the host from `.mcp.json` (a proposal, never
    authority) + the app card. Flagged.
  - *Cursor/Codex identity:* only Claude's `mcp__` naming is parsed; Cursor's
    `beforeMCPExecution` / Codex forms fall through to "normal tool call" until
    their hook payloads are mapped. Matches the plan's "unknown → normal".

## Live "done when" (needs you)
The Oct 22 MCP task: one ask, a single approval covering the tool + its host for
the session, session B still blocked. Blocked on the follow-on grant/host-link
above; the decision + display half is live now.
