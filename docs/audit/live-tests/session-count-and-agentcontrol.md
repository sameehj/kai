<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Session count + Agent Control layout (live test)

## 1. Session count was inflated by daemons/supervisors

**Diagnosis (live):** the scan reported 3 Claude + 2 Codex; the real interactive
set is 1 Claude + 2 Codex. The two extra "Claude" were Claude Code's own
background processes:

| pid | ppid | tty | elapsed | command | verdict |
|---|---|---|---|---|---|
| 87111 | 87017 | ttys000 | 13h | `codex` | session |
| 2993 | 2429 | ttys006 | 9d | `codex` | session |
| 3853 | 2423 | ttys001 | 8d 23h | `claude` | session |
| 16992 | **1** | **??** | 1d 18h | `claude.exe daemon run …` | **background service** |
| 35588 | **1** | **??** | 8d | `claude.exe --bg-pty-host …` | **background service** |

The "user / 1d 18h" row you asked about is pid 16992 — Claude Code's **daemon**
(reparented to launchd, no tty), not an orphan.

**Fix:** a pure classifier `kai_classify_session(cmdline, has_tty,
parent_is_launchd, age, nested)` → session / nested / background service /
idle-orphaned:
- an agent whose ANY ancestor is the same agent is **nested** (folded into that
  session, not counted) — full-ancestry check, not just the direct parent;
- `daemon run` / `--bg-pty-host`, or no-tty-and-reparented-to-launchd, is a
  **background service**;
- no tty + stale > 24h is **idle, possibly orphaned**;
- otherwise a **session**.
The scan now records the controlling **tty** (terminal window/tab) and host app
per session; `kai sessions` lists interactive sessions (with their window) and
lists background services apart; only sessions are counted.

**Tests:** `run_storage_tests` → `test_session_classify` (fixtures for session /
daemon / bg-pty-host / launchd-no-tty / nested / idle-orphan). Live `kai
sessions` now shows 3 interactive sessions (claude ttys001, codex ttys000/ttys006)
and the two Claude daemons as background services.

## 2. Agent Control window was blank — layout fix

Replaced the nested split view with a plain **HStack**: a fixed-width (300 pt)
`List` + a detail view, both filling the height; the first session is selected
by default so the detail isn't empty. (`AgentControlPage`, `SettingsView.swift`.)

**Note on the snapshot test / screenshot:** the repo has no Swift/XCTest target,
so a rendering snapshot test can't be added without new test infrastructure, and
this environment can't headlessly render SwiftUI or drive the app UI to capture
the window (AppleEvents automation is denied here, `-1743`). The layout is
verified by the data path (`kai sessions --json`, tested) and the live test
below. If you want a real snapshot test, say so and I'll add an XCTest target
with `ImageRenderer`.

## Protected-file block ~21m ago

`~/.kai/policy` and `~/.kai/registry`, blocked for the **unsigned repo `./kai`**
I ran while debugging (under this agent tree) — the wall correctly denied the
unsigned binary. Not a Claude Code block.

## Live test (human) — reinstalled app

1. **Count.** The popover and Agent Control show 1 Claude + 2 Codex (your 2+2
   when both Claude sessions are live); the Claude daemon and bg-pty-host appear
   under "Background services", not as sessions. Each row shows its window/tab
   (ttys00x) or host app. Result: ______
2. **Agent Control opens populated** — list on the left (300 pt) filling the
   height, first session selected, detail shown (not blank, no header overlap).
   Result: ______
