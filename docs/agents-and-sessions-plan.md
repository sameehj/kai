<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai — Agents, Sessions and Permissions: Build Instructions

*October 25, 2026. For Claude Code. Builds on `docs/walls-usability-sprint.md` (U0–U6), `docs/walls-action-plan.md` (rules) and `docs/walls-ux-evaluation.md` (problems #1–#23).*

## What we are building

One place in Kai where the user can:

1. **See every agent**: installed, hooked, and currently running.
2. **See every session** of each agent: which project, when it started, what it is about, what it touched, what Kai denied.
3. **Give a specific permission to a specific session**, quickly, including an override of a policy block, without turning a wall off and without affecting any other session.
4. **Watch each permission's lifecycle**: requested → granted → received by the walls → used → expired or revoked.

**Final acceptance (S8):** two Claude Code sessions and one Codex session run at once with both walls in Block. The user opens the Agents window, sees all three with topics, gives session A access to innermonkeylabs.com for this session only, and overrides a policy block on one file for session C for 15 minutes. Both work on retry. Session B stays fully restricted. Everything expires on schedule, and every step is visible in the UI.

---

## Rules for this work

All rules in `docs/walls-action-plan.md` apply. In addition:

1. **Agents request; only the user grants.** Every grant and override is created by an explicit click in the Kai app. Nothing the agent writes, and no CLI command run from an agent tree, creates or widens a permission.
2. **Agent-reported data is display-only.** Session titles, topics and hook-supplied ids are shown to the user, labelled "reported by agent", and never used for an authorization decision. Authorization uses only what Kai observes (process identity from Endpoint Security).
3. **Kai's own components are not agents.** Kai's hooks and the signed `kai` binary may read Kai's policy inside agent trees; nothing in an agent tree may write it.
4. **Develop Kai against a sandbox.** When working in the Kai repo, all tests and dev runs use `KAI_HOME=/tmp/kai-dev` (or similar), never the real home control store.
5. **One step at a time.** Tests first; implement; `make test` and the signed build pass; commit; write the live test script to `docs/audit/live-tests/S<N>.md`; stop for the human. A step is done only when its live test passes.

---

## Concepts and data model

### Agent
A recognized agent product: Claude Code, Codex, Cursor, Gemini CLI, plus user-defined agents.
- `id`, `name`, `signing identity` (Team ID / signing id, path fallback)
- `installed` (app bundle or CLI found), `version`
- `hooks` (Kai hooks installed? healthy?)
- `wall coverage` (recognized by storage and network walls?)

### Session
One running instance of an agent, from root process start to exit.
- `id`: assigned by Kai when Endpoint Security sees the agent's root process exec; keyed on its **audit token** (never PID alone)
- `agent`, `agent_version`
- `root process`, `started_at`, `ended_at`
- `project`: canonical working directory at root exec; git root stored as metadata only
- `host app`: terminal or app it runs in (Terminal, iTerm, Cursor, …)
- `hook_session_ids`: ids the agent's hooks report (e.g. Claude Code's `session_id`), bound to this session only when the reporting hook process is inside this session's process tree
- `topic`: agent-reported; redacted through libkai before storage
- `state`: active / paused / ended
- counters: files read, denials, hosts contacted, commands run, active grants

A process whose lineage Kai cannot verify (for example detached to launchd) belongs to **no session**. It appears under "Unattributed processes" and can never use a session's permissions.

### Permission (grant)
- `id`, `session_id` (or `project_id` for project scope)
- `resource`: one of
  - `path` (exact file)
  - `folder` (path prefix, never above the project root without a break-glass confirm)
  - `host` or `host:port`
- `operation`: read / write / connect / exec
- `scope`: task (10 min) / session (until the session ends) / project (persistent, revocable)
- `tier`: normal / override / break-glass (see below)
- `expires_at`, `created_at`, `created_by` (user, via app; whether Touch ID or the login password was used)
- `reason` (optional user note), `generation`
- lifecycle state: pending → granted → observed by storage wall / network wall → used → expired / revoked

### Override tiers
Each policy rule declares how far it can be overridden, for example `override: normal | confirm | breakglass | never`.

| Tier | Example | How the user approves | Limits |
|---|---|---|---|
| **Normal** | New host for an MCP server; a project file outside the allowed set | One click in the decision card | Task, session or project scope |
| **Override** (policy says block) | A blocked host or a protected project `.env` | Click plus a confirm sheet stating "This overrides your policy rule *X* for this session only" | Task or session only; never project-wide from the card |
| **Break-glass** | A private key, cloud credentials, anything the policy marks breakglass | Touch ID or login password (LocalAuthentication) in the Kai app | One resource, one session, the requested op (read or write), at most 15 minutes, persistent red banner while active |
| **Never** | Writing Kai's policy, grant store or pending changes; disabling Kai from an agent | Not offered; the card explains why | — |

Defaults: Kai's control store is `never`. Private keys and cloud credentials are `breakglass`. Other protected paths and blocked hosts are `confirm`. Everything else is `normal`. A future Teams policy can lock tiers centrally.

### Session summary
Two clearly separated parts:
- **Reported by agent:** a title or topic from hooks, such as the first user prompt (truncated to about 80 characters, redacted by libkai), or a session title if the agent provides one. Stored locally only. Can be turned off in Settings.
- **Observed by Kai:** project, duration, files read and written (counts plus a top-5 list), hosts contacted, commands run, denials, grants used.

Do not send prompts to any model to summarize them. The summary is built locally from hook data and Kai's own events.

---

## Where session data comes from

**Endpoint Security (authoritative).** The root exec creates the session. Fork, exec and exit events maintain the tree. Exit of the root ends the session.

**Agent hooks (descriptive).** Kai's installed hooks already run on agent events. Extend them to send a small, redacted session report to Kai on session start, each user prompt and session end:
- **Claude Code** hook input includes a `session_id`, `transcript_path`, `cwd` and the event name. Use `SessionStart`, `UserPromptSubmit` and `SessionEnd` (verify the current hook event list and fields against Anthropic's hooks documentation before coding).
- **Codex and Cursor:** use whatever session or conversation id and events their hooks expose; verify against the installed versions and record which fields exist.
- Agents without hooks get sessions from Endpoint Security only, with no topic.

**Binding.** When a hook process reports `session_id = X`, Kai looks up which session's process tree contains that hook process and binds X to it. A report from a process outside any session, or one claiming an id already bound elsewhere, is ignored and logged.

---

## UI specification

### Menu bar
- Headline from **observed** enforcement only (U1): "Protected", "Partly protected: storage is logging", or "Not protected".
- Summary line: "3 agents running · 1 needs you". Clicking it opens the Agents window filtered to sessions that need attention.
- Pending decision cards appear at the top.

### Agents window
**Left column: Agents.** Each installed agent shows name, version, hooks status (installed / missing / failing), wall coverage (recognized / not recognized), and the number of running sessions. Below the list: "Unattributed processes (n)".

**Main area: Sessions.**
- Table of sessions: agent icon, topic (reported), project, host app, started, state, denials, active grants. Needs-attention sessions sort first.
- Filters: running / ended today / all; agent; project.

**Session detail** (opens on selection, or directly from a notification):
- **Header:** agent, topic (labelled "reported by agent"), project, started, host app, state, and buttons: *Pause Kai for this session (15 min)*, *End session's permissions*.
- **Needs you:** pending requests as decision cards (below).
- **Permissions:** active grants with resource, operation, tier, countdown, lifecycle state (granted / received by walls / used) and *Revoke*. Plus an **Add permission** button for granting ahead of time:
  - resource type (file, folder, host)
  - file or folder picker, or host field
  - operation
  - duration (task 10 min / this session / project)
  - the tier is computed from policy; overrides and break-glass escalate the confirmation automatically
- **Activity:** this session's decisions, filterable by allowed, denied, would-block, pending.
- **Observed summary:** counts and top lists.
- **Process tree:** attributed processes and any that left the tree.

### Decision card (notification, menu bar and session detail)
> **Claude Code · session "update landing pages" · project website**
> Denied: connect to innermonkeylabs.com:443
> Reason: destination not on allowlist · Network wall · Block · 10:42
> [Allow for 10 min] [Allow this session] [Keep blocked] · More…

- "More…" offers project scope and lets the user narrow the resource (e.g. exact path versus folder).
- Policy-blocked resources show **Override for this session…** leading to the confirm sheet.
- Break-glass resources show **Override with Touch ID…**.
- Never-tier resources show "Kai protects its own settings; this can't be approved from here" and no buttons.
- In Watch (log) mode: "Allowed; would be blocked in Block mode", with no approval buttons.
- Identical requests are grouped with a count.

### After approval
The card becomes a status line: "Allowed this session · received by network wall · waiting for retry", then "used 10:43". If the wall has not observed the grant within the refresh bound, it shows "Not yet active", never "Allowed".

### Pause Kai for this session
Hooks and walls skip only this session, for 15 minutes or 1 hour, with a banner and auto-resume. Never-tier protections still apply. This replaces turning a wall off.

### CLI (read-only)
`kai agents`, `kai sessions`, `kai session show <id>`, `kai grants --session <id>`. No grant creation from the CLI.

---

## Build steps

Dependencies: **S0 first.** U1 (truthful state) must be done before any S-step live test can be trusted. U2 (notification pipeline) must be done before S6. U3's process-grant loop is superseded by S4 but its tests stay.

### S0 — Stop Kai blocking itself (urgent)

On October 25 the storage wall denied Kai's own `UserPromptSubmit` hook reading the policy file (event 555e2e42ba). The hook failed closed and blocked every prompt.

**Work**
1. Confirm which `kai` binary each installed hook invokes. Hooks must call the signed `/Applications/Kai.app/Contents/Resources/kai`.
2. The signed `kai` may **read** Kai's control store inside agent trees; writes stay denied (U0 rule). Every other agent-tree process reading the policy stays denied, because the policy contains company terms.
3. Hook error behaviour: tool-use hooks fail closed with an actionable message; the prompt-submit hook warns but does not block when Kai itself is the cause ("Kai can't read its policy — open Kai → Activity").
4. Dev sandbox: all repo tests and dev runs use `KAI_HOME`; add a guard that refuses to run tests against the real home control store.

**Automated tests:** signed kai read allowed in an agent tree; unsigned process read denied; any agent-tree write denied; hook error paths; test harness refuses the real home control store.

**Live test (human):** storage in Block. (1) A Claude Code prompt works. (2) Reading the policy file directly from the agent is denied, and the card shows no Allow button. (3) Activity shows the hook's read as allowed for the signed kai.

### S1 — Session identity

**Work:** session created at agent root exec (audit token), inherited by descendants, ended at root exit. Project recorded at root exec. Unverifiable lineage → no session. Persist a session registry (SQLite under Kai's control store) written only by Kai components.

**Automated tests:** child and grandchild inherit; two sessions of the same agent get distinct ids; root exit ends the session; a launchd-detached process gets no session; spoofed environment or working directory does not change the session; registry is unwritable from agent trees.

**Live test:** start two Claude Code sessions in different repos and one Codex session. `kai sessions` lists three with the correct projects. Exit one; it shows as ended within the refresh bound.

### S2 — Agent inventory

**Work:** detect installed agents (app bundles, CLIs on PATH, versions), hook installation and health per agent, and wall recognition. `kai agents` output.

**Automated tests:** detection with fixtures for present, absent and outdated; hook health states.

**Live test:** `kai agents` matches reality on the test Mac, including one agent with hooks removed (shown as missing).

### S3 — Hook session reports and summaries

**Work:** extend Kai's hooks (Claude Code first, then Codex and Cursor) to send redacted session reports on start, prompt and end. Bind hook ids to sessions per the binding rule. Build the observed summary from Kai events. Setting: "Show session topics" (on by default, local only).

**Automated tests:** binding accepted only from an in-tree hook process; spoofed or duplicate ids rejected and logged; topic redaction (a secret in the first prompt never reaches storage); summary counters.

**Live test:** a Claude Code session with the first prompt "update landing pages on innermonkeylabs.com" shows that topic (redacted where needed) and correct counts. A first prompt containing a fake AWS key shows the key redacted.

### S4 — Session-scoped permissions and override tiers

**Work:** grant model above, with `override:` attributes on policy rules and default tiers. Grants match on session id plus resource plus operation. Propagation to both walls with the generation counter, and the stated revocation bound. Session end expires session grants. Break-glass requires LocalAuthentication in the app. The grant-writing interface checks the caller's code signature and refuses agent trees.

**Automated tests:**
- Grant to session A applies to A's children and not to B.
- A task grant expires at 10 minutes; a session grant ends at session exit.
- An override-tier grant requires the confirm flag.
- A break-glass grant requires an authentication result, covers only the op it was signed for (read or write) and caps at 15 minutes.
- A never-tier resource cannot be granted at all.
- An unattributed process never matches a session grant.
- An agent-tree caller cannot create a grant.

**Live test:** see S8 steps 3–6, run early with one session.

### S5 — Agents window

**Work:** build the window per the UI specification: agents column, sessions table, session detail with all sections, unattributed processes. Data from S1–S4, refreshed live.

**Automated tests:** view-model tests for sorting (needs-attention first), filters, state labels ("Not yet active" until observed), and topic labelled "reported by agent".

**Live test:** with three sessions running, the window shows all three correctly. Ending one updates within the refresh bound. Unattributed processes appear when a detached child is started.

### S6 — Decision cards, Add permission, lifecycle, pause

**Work:** decision cards in notifications, menu bar and session detail per spec, with tier-aware buttons. Add-permission form. Lifecycle status line after approval. Pause Kai for this session. Grouping of identical requests.

**Automated tests:** card variants per tier and mode; grouping; lifecycle transitions; pause expiry and auto-resume; never-tier card has no actions.

**Live test:** trigger each tier once (normal host, confirm-tier project secrets file, break-glass private-key test fixture, never-tier policy file). Each shows the right card and confirmation. The lifecycle line progresses to "used" after retry.

### S7 — Permission manager and history

**Work:** a Settings page listing every active and recent permission across sessions and projects, with filters and Revoke; project-scope grants managed here. The audit log records every grant, use, expiry and revocation with caller details.

**Automated tests:** revoke reaches both walls within the bound; the audit record for each lifecycle event.

**Live test:** revoke a session grant while the agent uses it; the next attempt is denied and a new card appears.

### S8 — Acceptance: three concurrent sessions

Both walls in Block, on the test Mac.

1. Start Claude Code session A in the website project, Claude Code session B in another repo, and Codex session C in the Kai sandbox.
2. The Agents window shows three sessions with correct agents, projects and topics.
3. Session A runs the MCP task against innermonkeylabs.com. One card appears for A; the user clicks **Allow this session**. A retries and succeeds, including from new child processes. The lifecycle line reaches "used".
4. Session B runs `curl https://innermonkeylabs.com`. Denied; a separate card appears for B.
5. Session C reads a file the policy blocks (confirm tier). The user overrides it for the session via the confirm sheet. C succeeds; A and B still cannot read it.
6. Session C requests a break-glass test credential. Touch ID is required; access is read-only and ends at 15 minutes, with the banner shown the whole time.
7. Any session trying to write Kai's policy is denied; the card has no buttons.
8. Pause session B for 15 minutes. B's blocked actions are logged as would-block; A and C remain enforced. Auto-resume happens on time.
9. Close session A. Its grant shows expired. A new session in the same project is denied innermonkeylabs.com until approved again.
10. The permission manager and audit log show every grant, use, expiry and revocation with caller details.

**Done when** all ten steps pass and are recorded in `docs/audit/live-tests/S8.md` with the build's commit hash.

---

## Kickoff prompt for each session

```
Read docs/agents-and-sessions-plan.md, docs/walls-usability-sprint.md and docs/walls-action-plan.md.
Work on step S<N> only (S0 first). Follow both rule sets.
Tests first; implement; run make test and the signed build; commit; write docs/audit/live-tests/S<N>.md; then stop for me.
Use KAI_HOME for every dev and test run; never touch the real home control store except through the live test script I run.
```
