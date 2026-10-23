<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai Walls — Usability Sprint Plan (U0–U6)

*October 23, 2026. Branch base: `fix/approval-key-and-ux` (bf1a3e1, f25c9c7,
38f67b6). Companion to `docs/walls-action-plan.md` (rules, phases M0–M3) and
`docs/walls-ux-evaluation.md` (problems #1–#23).*

**Sprint goal:** the user can keep both walls in Block, see every meaningful
denial, approve a legitimate one for the right scope, and watch the agent succeed
on retry — with Kai reporting only what it has measured.

**Sprint acceptance test:** the October 22 replay passes on the installed, signed
extensions (U4).

---

## How Claude Code works through this plan

Start each session with:

```
Read docs/walls-usability-sprint.md, docs/walls-action-plan.md and docs/walls-ux-evaluation.md.
Work on step U<N> only. Follow the Rules in walls-action-plan.md.
Write the automated tests first, make them pass, then prepare the live test script and stop for the human.
```

For every step:

1. Write or update automated tests first; they must fail before the fix and pass after.
2. Implement the smallest change that passes.
3. Run `make test` and the signed enforcement build.
4. Commit on the sprint branch; record the commit hash.
5. Write the live test as a numbered script in `docs/audit/live-tests/U<N>.md` with expected output for each step.
6. **Stop.** The human installs the build, runs the live script and pastes results. A step is done only when its live test passes.
7. Report a table: each requirement → Live / Unit / Not tested.

Never mark a step done on unit tests alone. Never run live tests in Block mode on
the developer's main machine unless the human says so; use a test Mac or
disposable protected files.

---

## U0 — Safety baseline (no code changes)

**Why:** policy changed from log to block between 21:53 and 22:54 on October 23,
and it is not yet known who changed it. If an agent wrote Kai's policy, that
violates the most important invariant (#21, #23).

**Work**
- From Kai's audit log and file metadata, find every write to the policy file on
  October 23: time, process, code-signing identity, parent chain.
- Confirm with the human whether they switched the walls.
- Record current state: configured mode, observed mode per wall, extension
  versions active in `systemextensionsctl list`, commit hash of installed build.

**Automated test:** none (investigation).

**Live check (human):** confirm the finding.

**Done when:** the policy writer is identified. If it was an agent process, U0
becomes a blocker: make the policy and grant store hard-deny for all agent trees
(ES rule plus file ownership) before any other step, with a test that a tagged
process cannot write them.

---

## U1 — Truthful state (#18)

**Why:** Kai showed Block while storage was logging; network has no health
report. Nothing else in this sprint can be verified until Kai reports what is
actually running.

**Work**
1. Each extension loads mode, policy and grants together as one snapshot with a
   single version (hash + generation). Mode reloads on the same refresh path as
   grants; no setting is read only at startup.
2. Each extension publishes a heartbeat: wall, mode, enforcing (bool), snapshot
   version, grant generation, last refresh time, counters (decisions, denials,
   unattributed events).
3. Fix the network heartbeat: confirm where the network extension writes it and
   where `kai status` reads it (check sandbox and app-group container paths);
   make them agree.
4. `kai status` and the menu bar show **observed** state. Any difference from
   configured state is shown as a warning, e.g. "Storage: set to Block, actually
   Log". A missing or stale heartbeat (older than 2 refresh intervals) shows
   "Unknown", never "On".
5. Document the refresh interval; it is also the grant revocation bound (M1.1).

**Automated tests**
- Snapshot load: mode, policy and grants come from one versioned snapshot; a
  partial write is rejected and the previous snapshot is kept.
- Mode change while running: write Block, advance the refresh timer, heartbeat
  reports Block and enforcing=true.
- Stale heartbeat: status reports Unknown, not On.
- Configured ≠ observed: status JSON includes a `mismatch` entry; menu-bar view
  model shows the warning.

**Live test (human)**
1. Storage and network in Log. Run `kai status --json`: both observed log,
   enforcing=false, heartbeats fresh.
2. Switch storage to Block in the menu bar. Within one refresh interval, status
   shows observed block, enforcing=true; menu bar shows no warning.
3. Switch back to Log; same check.
4. Repeat 1–3 for network.
5. Quit the menu-bar app and relaunch; status unchanged.

**Done when:** configured and observed agree after every switch, for both walls,
within the documented interval.

---

## U2 — Notifications that actually arrive (#1, #4)

**Why:** the user receives no notification for items that need approval.

**Diagnose first** (record findings in `docs/audit/notifications.md`):
- Does the menu-bar app request notification permission, and what is the current
  authorization status (authorized, denied, not determined)? Focus modes can also
  hide notices.
- System extensions run outside the user session and cannot post user
  notifications themselves. Trace the path from a denial in each extension to the
  menu-bar app: what carries the event (XPC, shared store, log tail), and does
  anything arrive?
- Is an approval request created at all? In Log mode nothing is denied, so no
  approval request should exist; confirm the expected behaviour per mode.
- Is "Show what was blocked" still off by default? Is grouping or rate-capping
  suppressing everything?

**Work**
1. Pipeline: extension → approval-request record → menu-bar app → notification,
   with each hop logged by event id.
2. Default notifications on; request permission during first run with one
   sentence on why.
3. Add notification authorization status to `kai status` and to the menu bar.
4. Fallback when permission is denied or Focus hides it: menu-bar icon badge with
   count of pending approvals, and a Pending section at the top of Activity.
5. Group by session, resource and reason with a count; rate cap (e.g. at most 1
   notice per group per minute).
6. Log mode shows "would have blocked" entries in Activity only, no approval
   prompts.
7. Never offer approval for non-grantable classes (control files, private keys,
   Kai's own files): show "Blocked — not approvable" instead.

**Automated tests**
- Synthetic denial event in Block mode produces exactly one pending request and
  one notification request to the notification layer (mock), with the event id.
- 1,000 identical denials produce one grouped notice with count 1,000; UI model
  stays responsive.
- Permission denied: no notification call, badge count increments, Pending
  section populated.
- Log mode: Activity entry, no pending request.
- Non-grantable class: notice without approve actions.

**Live test (human)**
1. `kai status` shows notification authorization; grant it if asked.
2. Storage in Block on a disposable protected test file (grantable class). From
   Claude Code: `cat` the file. Expected: one notice within 2 seconds naming
   Claude Code, the file, the reason and the approve options; Activity shows it
   under Pending.
3. Repeat `cat` 20 times. Expected: still one notice, count updated.
4. Turn notifications off for Kai in System Settings; repeat step 2. Expected:
   badge and Pending entry, no notice.
5. Network in Block: from Claude Code, `curl https://example.com`. Expected: same
   behaviour for the network wall.

**Done when:** steps 2–5 behave as expected for both walls.

---

## U3 — Approval lifecycle, process scope (#9, #22, #23)

**Why:** the first approval failed: the grant never reached the running
extension. Prove the full loop with the current interim scope before widening it.

**Work**
1. Lifecycle with event ids at each stage: denied → request created → approved by
   user in Kai UI → grant written → grant observed by extension (generation
   increments in heartbeat) → retry → `grant_used` → expiry → denied again.
2. Approvals only from the menu-bar app via an explicit click; the grant-writing
   interface checks the caller's code signature and refuses any agent-tree
   caller; CLI grant commands refuse tagged callers.
3. Button text matches real scope: "Allow this process (15 min)".

**Automated tests**
- Grant created while extension running is observed within the refresh bound
  (also: first-ever grant; grant after extension restart).
- Grant matches pid + pidversion only; reused pid with a different pidversion is
  denied (already exists; keep).
- Expired grant: next decision denies, within the bound.
- Agent-tree caller of the grant interface or CLI: refused and audited.

**Live test (human)**
1. Storage Block. Claude Code runs a long-lived reader (e.g. `python3 -c` loop
   reading the test file every 5 s).
2. Approve "Allow this process" from the notice.
3. Expected: next read succeeds; log shows `grant_used` with the same event id;
   heartbeat grant generation increased.
4. In a new process, `cat` the file. Expected: denied with a new notice
   (documented interim limitation).
5. Wait 15 minutes. Expected: the long-lived reader is denied again; no manual
   action needed.
6. From Claude Code, try `kai grant ...` (or whatever the CLI exposes). Expected:
   refused, audited.

**Done when:** steps 3–6 pass.

---

## U4 — Session scope and the October 22 replay (#10, #15, #19)

**Why:** "per session" approval is what the user expects, and what October 22
needs; process scope cannot pass it.

**Work**
1. Session id assigned at a known agent's root process exec (keyed on audit
   token), inherited by all descendants. Project recorded at root exec (canonical
   working directory; git root as metadata only).
2. Processes with unverifiable lineage, including launchd-detached ones, get no
   session and cannot use session grants.
3. Notice options become: This task (destination for 10 min within this session),
   This session, This project, Keep blocked. No "Always allow".
4. `kai denials --mine` and `kai why <id>` return only the caller's own session
   records.

**Automated tests**
- Child and grandchild of a session root inherit the session id.
- Two sessions of the same agent get different ids; grant to A does not match B.
- Reparented-to-launchd process: no session; session grant does not apply.
- Spoofed session metadata (environment variables, cwd) does not change the
  session id.
- `--mine` from session B cannot see session A's records.

**Live test (human) — October 22 replay**
1. Both walls Block. Two Claude Code sessions: A in the website project, B in
   another repo.
2. Session A: run the MCP task against innermonkeylabs.com. Expected: one notice
   naming session A, the host and the reason; Claude reports the Kai denial (via
   `kai why`) rather than "no internet".
3. Approve "This session".
4. Session A retries. Expected: success, including connections from new child
   processes.
5. Session B: `curl https://innermonkeylabs.com`. Expected: denied.
6. Close session A; start a new session in the same project; retry. Expected:
   denied (session grant ended).
7. Throughout: `~/.ssh` reads from either session denied with no approve option.

**Done when:** all seven steps pass.

---

## U5 — Defaults that do not break the agent (#5, #6, #7, #13, #21)

**Work**
1. Minimal Claude Code profile: core channels (api.anthropic.com, claude.ai,
   claude.com, platform.claude.com) routed through the AI proxy; read access to
   `~/.claude/settings.json` and project `.claude/settings.local.json`; session
   history restricted cross-session.
2. MCP discovery: watch MCP config files; new endpoints appear in Activity as
   "pending review" with file, time and writing process; never auto-granted.
3. **Open decision — Codex `config.toml` writes.** Option A: keep writes blocked
   (current). Option B: allow writes, treat every change as untrusted, flag new
   MCP endpoints for review. Human decides; record the decision in the profile.

**Automated tests**
- Profile load: Claude Code settings reads allowed; `~/.claude/projects/` of
  another session denied.
- An agent adding an MCP server to its config creates a pending review item and
  no grant.
- A direct connection from a tagged process to a model host that bypasses the
  proxy is dropped.

**Live test (human)**
1. Both walls Block. Start Claude Code fresh. Expected: it starts, signs in,
   reads its settings, answers a prompt — zero notices.
2. Add an MCP server to `.mcp.json`. Expected: pending review entry; first
   connection denied until approved.
3. Codex: perform a read of `config.toml`, then the action covered by the open
   decision; expected per the decision.

**Done when:** Claude Code runs a normal session in Block with no notices and no
exceptions beyond its profile.

---

## U6 — Safe pause and Activity polish (#4, #11)

**Work**
1. "Pause 15 min / 1 hour" per wall, auto-resume, notice on resume; full disable
   moved to Settings with a persistent menu-bar warning while active.
2. Activity filters: agent, session, project, allowed, denied, pending,
   would-block (log mode).

**Automated tests**
- Pause sets an expiry; heartbeat reports paused; resume happens at expiry without
  user action.
- Disable shows a persistent warning state in the menu-bar model.

**Live test (human)**
1. Pause storage for 15 min. Expected: status shows paused with time left; after
   expiry, observed Block, enforcing=true, resume notice.
2. Filter Activity to one session; only its entries show.

**Done when:** both pass.

---

## Sprint exit checklist

- [ ] U0 policy writer identified; agent writes to Kai policy proven impossible
- [ ] U1 configured and observed state agree for both walls
- [ ] U2 notices arrive for both walls; fallback works without permission
- [ ] U3 approval loop proven live with process scope
- [ ] U4 October 22 replay passes with session scope
- [ ] U5 Claude Code runs a normal session in Block with zero notices
- [ ] U6 pause auto-resumes
- [ ] Every step has a live test record in `docs/audit/live-tests/` with the build's commit hash
