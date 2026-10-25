<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Session visibility + popover redesign (live test)

Sessions visible without the storage wall, honest enforcement labels, the
popover restructured, Agent Control as the first Settings page, and
session-wide grant matching.

## What changed (the 5 items)

1. **Storage-wall-free session discovery.** `kai sessions` now merges:
   - the ES registry (authoritative, storage wall active), and
   - a **process scan** (`kai_sessions_scan`, `src/proc.c`): finds agent ROOT
     processes by the policy's agent rules (code signing / exe / arg), recording
     start time, working dir, host app (Terminal/iTerm/Cursor/…) and child count.
   Deduped by root pid (registry wins). Each session carries an **enforcement
   label** from observed wall state (`kai_enforcement_label`): "Enforced by both
   walls" / "Network wall only" / "Storage wall only" / "Seen, not enforced:
   storage wall off". It **never says "protected"** for a session no active wall
   can attribute. A network **health snapshot** (`/tmp/kai-network-health.json`,
   written by the network extension) makes "Network wall only" truthful, and
   `kai status` now reads it.
2. **Popover = the redesign structure** (`MenuView`): a short status headline +
   a full second line (observed state, no truncation); **Needs you** (pending
   cards); **Active now** (one row per running session: agent, enforcement,
   project, started HH:MM, running-for, grant count, chevron → opens its detail);
   **Permissions** (grouped, countdown, Revoke); **Recent** (grouped with
   counts); **Open Agent Control**. The big shield and weekly counters are gone
   from the popover (counters stay in the window).
3. **Agent Control** is the **first Settings sidebar item** (`AgentControlPage`):
   sessions list + detail (Add permission / Revoke / Pause this session). Popover
   session rows and "Open Agent Control" open it.
4. **One observed-state source.** The popover and the Settings sidebar both use
   `AppModel.observedHeadline(storageOn:networkOn:)`; the sidebar no longer shows
   a blanket "All protected" — it reflects observed enforcement (item 4 fix).
5. **Session-wide grant matching** (`kai_grant_match`): a grant carrying a
   session id matches **any process in that verified session** (the whole tree,
   incl. new children), not one pid; a grant with no session id stays pid-bound.

## Automated tests — PASS (`make test`, exit 0)

- `test_enforcement_labels`: both/network-only/storage-only/not-enforced labels;
  the no-wall label never contains "protected"; the scan returns a sane count.
- `test_grant_tiers`: a session grant covers a DIFFERENT pid in the same session,
  and does NOT cover a different session (session-wide matching).
- Existing suites stay green (106/0, storage, hooks, cli, gateway, browser,
  corpus, escape). The popover/Agent Control UI is SwiftUI (no Swift test target);
  its data (`kai sessions`/`kai agents --json`) is covered above, and the UI is
  verified by the live test.

Engine behaviour already confirmed live: with the storage wall OFF, `kai
sessions` discovered the running claude + codex sessions with projects, labelled
"Seen, not enforced: storage wall off".

## Live test (human) — reinstalled app (storage v23 / network v9)

1. **Storage OFF — sessions appear.** With the storage wall off, open the popover.
   Your 2 Claude Code + 2 Codex sessions appear under **Active now** with correct
   start times and durations, labelled **"network only"** (network wall on) or
   **"not enforced"** (both off). Never "protected".
   - Expected: sessions visible without the storage wall, correct labels. Result:
2. **Turn storage on.** Activate the storage wall; the same sessions now show
   **"both walls"**.
   - Expected: label flips to enforced-by-both. Result: ______
3. **Per-session grant + revoke from the popover.** Open a session's detail
   (click its row → Agent Control), grant a permission, use it; revoke it. The
   other sessions are unaffected; a session grant covers the whole session (incl.
   new child processes).
   - Expected: grant/revoke scoped to one session; others unaffected. Result: __
4. **Sidebar/headline honesty.** The Settings sidebar and the popover headline
   reflect observed enforcement (no blanket "All protected").
   - Expected: truthful status. Result: ______

### Results (filled after the live run)

- [ ] 1 sessions visible with storage OFF, correct times + labels —
- [ ] 2 storage on → "both walls" —
- [ ] 3 per-session grant/revoke from popover; others unaffected; whole-tree —
- [ ] 4 sidebar/headline observed-only —
