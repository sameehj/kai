<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Durations: long grants, short pauses (live test)

**Grants** can be long (a narrow, revocable, counted-down permission); **pauses**
cannot (a long pause is the wall switched off).

## What changed

- **Grant durations** (`Approvals.swift`): the decision card's normal/confirm
  tier offers an **Allow…** menu with **10 min / 1 hour / 1 day / 7 days / this
  session**; override tier offers **This session / 1 day** (task-or-session only,
  never project-wide from the card); break-glass stays Touch ID + 15 min
  read-only. Each grant carries `expires_utc` and shows a countdown; all are
  revocable. "this session" binds to the ES session (covers its whole tree, ends
  at session exit) via the session id now carried on the pending request + the
  session-wide matcher.
- **Pause capped at 1 day** (`kai_session_pause_write`, `src/session.c`): a
  request over 24 h is clamped to 24 h. 15 min / 1 hour / 1 day only. (The
  persistent banner + end-of-pause reminder are the remaining UI piece of this
  item.)

## Tests — PASS

`run_storage_tests` → `test_session_pause`: pause/auto-resume/resume, and a
10000-minute request is **capped at 1 day** (paused at 23 h, not at 25 h).
Session-wide "this session" grants are covered by `test_grant_tiers`
("a session grant covers a different pid in the same session"). `run_tests`
106/0; app + extensions compile.

## Live test (human)

1. **Longer grant.** On a decision card choose Allow… → **7 days** (or 1 day) for
   a host/folder. The grant shows a 7-day countdown in Permissions and is
   revocable; a new child process of the same session is covered if you chose
   "this session".
   - Result: ______
2. **Pause is short.** Pause a session; only 15 min / 1 hour / 1 day are offered;
   there is no multi-day option. (Banner + reminder pending.)
   - Result: ______
