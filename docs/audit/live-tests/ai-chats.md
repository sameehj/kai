# Item 3 — AI chats section

## What it does
Shows where AI is being used through a **browser** (claude.ai, chatgpt.com,
gemini.google.com, …), not just through CLI/IDE agents. These web chat UIs are
not CLI agents — the walls protect files on disk, not a browser tab — so this is
VISIBILITY ONLY: Kai never gates, grants for, or blocks a browser chat.

## Why not the browser extension
The shipped browser integration (`src/browser.c`) is install-only: it registers
a native-messaging host but has no pipeline that reports chat activity back to
Kai. Rather than invent an unverifiable extension data path, item 3 reuses the
network wall's existing flow observation (same mechanism as item 5 discovery):
when a non-agent process (typically a browser) reaches an AI-chat web host, Kai
records it.

## Engine pieces (src/session.c, include/kai.h)
- `kai_host_is_ai_chat(host)` — matches AI chat WEB UI hosts, kept as a list
  separate from `kai_host_is_model_api` so a browser on claude.ai is reported as
  a chat, not mistaken for an unrecognized agent (claude.ai appears in both).
- `kai_chat_record(exe, host)` / `kai_chat_load()` — one JSON per (exe, host)
  under the home `chats` dir, keyed by sha256(exe|host); re-seeing a pair just
  refreshes `last_utc`. Same control-store write rules as everything in the home
  tree — agent-tree writes are refused.

## Network extension (app/macos/Network/FilterDataProvider.swift)
- `recordModelContact(pid, flow)` runs on flows from processes Kai does NOT
  recognize as agents. AI-chat web host -> `kai_chat_record` (item 3); otherwise
  a model API -> `kai_discovery_record` (item 5). Chat UIs are checked first.
  Deduped per run by `exe|host` (the `discoverySeen` set) so there is no
  per-packet file I/O on the hot path.

## CLI (src/manage.c)
- `kai agents` prints an "AI chats (web UI; visibility only, not gated)" section
  listing each app and the chat host it reached. JSON mode emits
  `{name, kind:"ai-chat", exe, host}` entries.

## Automated tests (tests/storage/run_storage_tests.c → test_ai_chats) — PASS
  - claude.ai / chatgpt.com / gemini are AI chats; the API endpoint and a random
    host are not
  - record a browser chat; a non-chat host is not recorded
  - the recorded chat loads back

## Live-test status
- Engine + CLI logic: PASS (unit-tested above).
- Network-extension recording path: NOT fully live-tested here. It needs a real
  browser TLS flow to an AI-chat host while network wall v10 is active, then
  inspecting the home `chats` dir. Documented as not-tested in this environment
  rather than claimed.

## Honesty notes
- Visibility only: no wall gates a browser chat, and nothing here grants or
  blocks anything.
- Hostname-based: it records that an app reached a chat host, not the content of
  any chat. No prompt or message text is read or stored.
