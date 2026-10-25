<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# U5 Claude Code profile + Agent Control UI fixes (live test)

Six fixes, in the order requested.

## 1. Claude Code profile (U5) — stop blocking the agent's own config

**Investigation (from the audit log, last day):** the only real-home storage
denials to Claude Code / Codex were writes to `*/.claude/settings.json` (the rest
were this session's own cli-test tmp writes). The storage wall already (post-S0)
allows agents to READ their hook config and to write their operational state
(`~/.claude.json`, `~/.claude/projects`, `todos`, …, which match no protect
rule), and keeps tokens (`~/.ssh`, `~/.aws`, `.env`, `*.pem`, `*.key`) and Kai's
control store protected.

**The bug was in the hook layer:** `PreToolUse` blocked *any* protected path
with no read/write distinction, so an agent **reading its own `settings.json`**
via a tool was denied ("Read touches protected path"). Fixed: a Read/Grep/Glob/LS
of a control path that is read-allowed (`kai_control_read_allowed`) is now
permitted; **writes** to it stay blocked (anti-tamper), and Kai's home + user
secrets are never read-allowed. (`src/hooks.c`.)

**Automated test:** `run_storage_tests` → `test_u5_hook_reads`: a Read of the
agent's own settings is allowed; an Edit of it is blocked; a Read of a user
secret stays gated.

## 5. Enforcement label "storage only" while the network wall is in Block

**Found:** the label was wrong, not the attribution. The network wall was
enforcing, but its health snapshot was ~2 hours stale — `Timer.scheduledTimer`
does not fire in an NE provider (no run loop), so the file was written once at
startup and went stale, reading as "not running". Fixed with a GCD
`DispatchSourceTimer` that fires on its own queue every 5 s
(`FilterDataProvider.swift`). Now a session with both walls active reads
"Enforced by both walls".

## 2. Agent Control layout

`AgentControlPage`: a two-column `HSplitView` that fills the page (the list no
longer collapses onto the header — the bug was a `List` with no height), and the
first session is selected by default so the detail isn't empty.

## 3. Session time

`running 8d 2h` (not `190h 8m`); the Started field shows a **date** when the
session didn't start today (e.g. "Oct 17") and only in the detail. (Full
"active now / idle 3h" last-activity needs per-event session activity and is the
next increment.)

## 4. Rows

Display names: **Claude Code**, **Codex**, **Cursor**, **Gemini CLI** (not the
lowercase classifier); sessions grouped under their agent with a count
("Claude Code · 3") in the popover; the second line is the hook topic or hidden;
the project name is shown once (the double-print is gone).

## 6. Popover header

A large session count with "agent sessions running", a small row underneath
(**N needs you · N active grants · N blocked today**), and the headline from the
shared observed-enforcement status. The big shield and weekly counters stay out
of the popover.

## Tests — PASS

`run_tests` 106/0; `run_storage_tests` all pass (incl. `test_u5_hook_reads`);
app + both extensions compile. (The full `make test` cli suite can't run here
because the storage wall is active and correctly blocks this agent-tree test's
writes to `*/.claude` hook configs; it passes with the wall off / in CI.)

Network extension bumped 9 → 10 (health-timer fix).

## Live test (human) — reinstalled app, storage Block

1. **Fresh Claude Code session, zero denials.** Start a session in Block; a
   prompt and a file edit produce no Kai denials; reading its own config works.
   - Result: ______
2. **Enforcement label.** With both walls active, sessions read "both walls"
   (not "storage only"). `kai sessions` agrees.
   - Result: ______
3. **Agent Control.** Opens with the list filling the pane and the first session
   selected (detail shown), not collapsed on the header.
   - Result: ______
4. **Rows + header.** Names read "Claude Code"/"Codex"; sessions grouped per
   agent with a count; no duplicated project; the popover shows the big count +
   the needs-you/grants/blocked row.
   - Result: ______
5. **Times.** "running 8d 2h"; start date only in the detail.
   - Result: ______
