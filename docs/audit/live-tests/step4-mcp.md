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

## Session grants + one-card-two-grants (now implemented)
- **Honor a session grant (src/grant.c, src/hooks.c):** `kai_mcp_grant_allows`
  — a session-bound grant with resource `mcp:<server>/<tool>` (or a server
  wildcard) allows the call outright. The hook loads grants + the approval key
  (`kai_approval_key_read`) and verifies the HMAC; the signed hook is read-exempt
  so it can, and an agent cannot forge a grant. A different session has no such
  grant and is asked again.
- **Declared host (src/grant.c):** `kai_mcp_declared_host` reads the server's
  host from `.mcp.json` — a proposal only (M2.5), never authority.
- **One card, two grants (hooks.c + Approvals.swift):** on an MCP ask the hook
  stages a Kai approval request under `<home>/pending` (resource + session +
  declared host; dedup'd per session+tool). Approving it in the app
  (`signGrant` → `emitGrant`) writes BOTH a session grant for the tool and, when
  a host was declared, a session egress grant for that host — so the agent's
  connection to the server isn't a second prompt. The ask text also names the
  host.

## Automated tests (test_mcp_grants, 8) — PASS
  - a session grant allows its tool; a different session / tool is not covered;
    a grant edited after signing is rejected; a server-wildcard covers any tool;
    an expired grant does not allow; `.mcp.json` host parsed; unknown server has
    no host.

## Surface = Kai card only (resolved)
- The hook **never** returns Claude Code's native `ask` for MCP — in auto mode the
  agent could approve that itself with no Kai decision. Without a grant it returns
  **deny**: "Waiting for approval in Kai: <server> · <tool>. Approve in Kai, then
  retry." One Kai card grants the tool and its declared host for the session.

## Requests go through the XPC service, not files (Change 2)
- The hook no longer writes `<home>/pending` and no longer reads grants or the
  approval key. It makes ONE XPC call (`kai_control_request("mcp", …)`); the
  service (the signed app) does everything key-dependent.
- `kai_mcp_service_request` (grant.c): derives the session from the **caller's
  audit token** (`kai_session_for_pid`), never a payload id; honors a session
  grant (→ allow) or stages the pending card (→ waiting). A caller with no Kai
  session is denied.
- **Key safety:** the approval key is now unreadable by `kai` in an agent tree —
  `kai_path_is_approval_key` + the storage wall block every non-app reader
  (`approval-key-app-only`). Only the app (and the extensions, in their own code)
  read it.
- Test (`test_mcp_service`): a staged request's session comes from the token
  (sessB), not any payload; a no-session caller is denied; a session grant →
  allow (this last check skips under a live wall that blocks `*.key`; passes
  wall-off / CI; round-trip verified separately).

## Cursor/Codex identity (unchanged)
- Only Claude's `mcp__` naming is parsed; other agents fall through to "normal
  tool call" (the plan's "unknown → normal").

## Live "done when" (needs you + the running app)
The Oct 22 MCP task: one ask; approving in the Kai card covers the tool AND its
host for the session (two grants); session B still blocked. The engine + hook +
app code are all in; this needs the signed app to validate end to end.
