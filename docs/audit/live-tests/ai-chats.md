# Item 3 / v1 Step 2 — AI chats section (extension-sourced)

## What it does
Shows where AI is used through a **browser** (claude.ai, chatgpt.com, gemini, …)
alongside CLI/IDE agents. These web chat UIs are not CLI agents and the walls
don't apply to a browser tab, so this is **visibility only** — never gated,
granted, or blocked.

## Source: the browser extension, NOT the network wall
The network wall is **agent-only**: it never inspects, records, or gates a
process Kai doesn't recognize as an agent. The earlier approach (network wall
recording non-agent flows to AI-chat hosts) was removed — see
`redesign-sessions.md`/this doc's history. The single source is now the Kai
browser extension over native messaging.

- **Extension (`integrations/browser/background.js`)** reports a `status`
  message: the AI-chat sites currently open (by site), plus per-site redaction
  and override counts it has tracked. Site only — never a full URL, never any
  chat text. Needs the `tabs` permission (added to `manifest.json`).
- **Native host (`src/native.c`)** gains a `status` handler that records each
  reported site via `kai_chat_record(site, open_tabs, redactions, overrides)`.
  The host still cannot change policy or install anything.
- **Store (`src/session.c`)** `kai_chat_record`/`kai_chat_load`: one JSON per
  site under the control store (`<home>/chats`), keyed by site; a re-report
  updates counts in place. Agent-tree writes are refused like any control-store
  write.
- **CLI (`src/manage.c`)** `kai agents` prints an
  "AI chats (browser extension - walls don't apply)" section:
  `site — N open, N redacted, N sent anyway`. JSON carries
  `source:"browser extension"`, `coverage:"walls don't apply"`.

## Automated tests (tests/storage/run_storage_tests.c → test_ai_chats) — PASS
  - claude.ai / chatgpt.com / gemini are chats; API endpoint and random host are not
  - record a chat site from the extension; a non-chat site is not recorded
  - loads back with its counts; one row per site; re-report updates in place

## Live-test status (Step 2 "done when": live, a claude.ai tab appears under AI
## chats with no network-wall record of it)
- Engine + CLI + native-host logic: PASS (unit-tested).
- End-to-end (extension → native host → `kai agents`): **NOT tested here** —
  needs Chrome with the Kai extension loaded, a claude.ai tab open, then
  `kai agents` showing the site while the network wall shows no record of it.
  Record result here during the live walk.

## Honesty notes
- Visibility only; no wall gates a browser chat.
- Site only: no full URL and no chat text is stored or sent. Redaction/override
  counts are integers the extension already tracks for its own badge.
