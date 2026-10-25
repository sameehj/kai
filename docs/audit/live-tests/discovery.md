# Item 5 — Discovery: "looks like an agent"

## What it does
Kai watches which processes talk to model-API endpoints (Anthropic, OpenAI, etc.)
and, for processes that are NOT already recognized agents but (a) contact a model
API and (b) spawn shells, surfaces a suggestion: "Looks like an agent — protect it?"
This finds agents Kai does not yet know about, without weakening any wall.

## Engine pieces (src/session.c, src/proc.c, include/kai.h)
- `kai_host_is_model_api(host)` — matches known model-API hostnames.
- `kai_looks_like_agent(contacted_model_api, spawns_shells, recognized)` —
  returns true only when contacted && spawns_shells && !recognized.
- `kai_discovery_record()` / `kai_discovery_load()` — persist one JSON per
  discovered exe under the home `discovery` dir, keyed by exe sha256 (dedup).
- `kai_pid_exe(pid, buf, len)` — resolve a pid's executable path.
- Discovery store lives under the control store; agent-tree writes are refused
  like any other control-store write (no new write surface for agents).

## Network extension (app/macos/Network/FilterDataProvider.swift)
- `recordDiscoveryIfModelAPI(...)` is called on flows whose remote host is a
  model API. If the contacting process is not a recognized agent, it records a
  discovery entry. A per-process `discoverySeen` set avoids re-recording on the
  hot path (no file I/O per packet for already-seen pids).

## CLI (src/manage.c)
- `kai agents` prints a "Looks like an agent — protect it?" section listing
  discovered candidates (exe path, first-seen, model API contacted).

## Automated tests (tests/storage/run_storage_tests.c -> test_discovery) — PASS
  - anthropic is a model API / openai is a model API / a random host is not
  - model-API + spawns shells + unknown => suggest
  - no model-API contact / no shells / already recognized => no suggestion
  - record a contact (round-trips through the discovery store)

## Live-test status
- Engine + CLI logic: PASS (unit-tested above).
- Network-extension recording path: NOT fully live-tested here. It requires a
  non-agent process to make a real TLS flow to a model API while network wall v10
  is active, then inspecting the home `discovery` dir. Documented as not-tested in
  this environment rather than claimed.

## Honesty notes
- Discovery only SUGGESTS; it never auto-protects or grants anything.
- No wall is weakened to produce suggestions; reads of the discovery store follow
  the same control-store rules as the rest of the home tree.
