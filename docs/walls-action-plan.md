<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai Walls — Action Plan for Claude Code

Claude Code runs one phase per session: audit first, then M0 visibility, M1
grants, M2 profiles, M3 onboarding, each ending at a human checkpoint with
live-versus-unit test evidence. Problem numbers (#1–#23) refer to
`docs/walls-ux-evaluation.md`.

**Goal:** a user keeps both walls on through a normal working day without
disabling protection or editing policy files.

**Primary acceptance test:** replay October 22. With both walls on, Claude Code's
MCP request to innermonkeylabs.com is denied, the user sees why, grants access for
that one session, Claude retries and completes the task, and every other boundary
stays intact.

## Status checkpoint — October 23, 2026

This checklist marks a step complete only when its stated acceptance conditions
are met. Recent M0/M1 code does **not** make the phase acceptance tests pass yet.

| Area | Live | Unit / build | Remaining |
|---|---|---|---|
| Phase 0 audit | Oct 22 denials and detached-process gap observed | Component map and 23-problem table written | Drop errno/timing harness; direct-model-flow reproducer; refresh the audit after M0/M1 code |
| M0 visibility | Network v8 active in macOS, but `kai status` has no network heartbeat; storage v17 installed but inactive | Reason codes, Activity, notifications, `kai why` and `kai denials` built | Full event schema, `--mine` isolation, bounded activity filters, matching policy/grant hashes and attribution counters |
| M1 approvals | First approval on Oct 23 failed; no successful grant retry observed | Signed grant engine, pid+pidversion matching, first-key reload test, v17/v8 compile | Live first-key, running-grant, restart, new-process, expiry, revoke and Oct 22 replay tests; true session grants |
| M2/M3 | Not tested | Some basic UI exists | Agent profiles, MCP discovery, gateway routing guarantee, onboarding and full permission manager |

**Interim M1 permission:** the UI now offers “Allow this process (15 min)”. The
matcher requires **pid and pidversion**, not bare pid (`src/grant.c`), so PID reuse
alone cannot transfer it. A retry by a new `curl`, shell or MCP server process
is expected to be denied. M1.2's verified session identity and session-wide
grant matching remain the target. Record same-process success and new-process
denial separately in the live report; neither proves the Oct 22 acceptance test.

**M0.4 blocks further approval claims:** the storage extension's snapshot reports
mode and grant generation but not policy hash or attribution coverage. The
network extension currently emits no snapshot even though macOS reports v8
active. Before calling grants live-validated, record the policy and grant
generation actually loaded by each extension and reconcile macOS activation
with Kai's measured status. Test a grant created while running, after restart,
and with the very first key.

**Codex config write policy is undecided:** current builtin protection lets
agents read `.codex/config.toml` but denies writes, and grants cannot override
that control path. `codex mcp add` and trust-setting changes may require writes.
M2's Codex profile must choose deliberately between hard-denying those writes
or allowing them as untrusted changes with audit and MCP endpoint review. See
the open question in `docs/walls-ux-evaluation.md`. Do not loosen this rule as
a test workaround.

## How to use this plan

Start each session with:

```
Read docs/walls-action-plan.md, docs/walls-ux-evaluation.md,
docs/walls-macos-design.md and docs/open-source-and-apple.md. Execute Phase N
only. Follow the Rules section. Stop at the phase's human checkpoint and report.
```

## Rules (apply to every phase)

1. **Audit before building.** M0–M4 already produced a permission engine, CLI,
   grant store, UI wiring and tests. Extend them; rebuild only if the audit shows
   they cannot meet a requirement, and say why.
2. **Agents can request, never grant.** No code path may let a process in an
   agent tree create, modify or delete a grant or policy. Agent-owned config files
   are untrusted input, read for discovery only.
3. **Nothing blocks inside an Endpoint Security AUTH handler.** No IPC
   round-trips, prompts, file I/O, allocation or policy parsing. Approval is always
   deny now, grant later, agent retries.
4. **Never weaken a boundary to make a test pass.** No broad wildcards, blanket
   directory exceptions, or "allow all for agent X".
5. **Report what was tested live versus at unit level.** Every phase report has a
   Live / Unit / Not tested column.
6. **Do not claim security properties you have not demonstrated.** UI text says
   what Kai measured, not what it was configured to do.
7. **Small, reviewable changes.** One branch and PR per numbered step where
   practical; update the relevant doc in the same change.
8. **Stop and ask the human** before any human-only step, before turning a wall
   off on the developer's main machine, and whenever a step needs a decision the
   docs leave open.

## Phase 0 — Audit (no behaviour changes)

Output: `docs/audit/walls-audit.md`.

- [x] 0.1 Map the components: libkai, ES extension, NE content filter, NE
  transparent proxy, gateway, menu-bar app, CLI, grant store, hooks, policy
  loader, audit log. For each: entry points, how it reads policy and grants.
- [x] 0.2 Answer the five grant questions with evidence: can a live storage denial
  be approved and retried? Can a network grant be scoped to one session? Do expiry
  and revocation reach both running extensions, within what bound? Can an
  agent-tree process forge or misuse a grant (file, CLI, XPC, socket)? Can the user
  complete the October 22 task without disabling a wall?
- [x] 0.3 Policy and grant refresh: document how each extension reloads policy and
  grants; flag differences.
- [x] 0.4 Trace October 22: find the code that prints `Rule: <host>` on a no-match
  (#3); find from the audit log the exact paths denied when Claude Code lost its
  settings (#7); record shipped defaults.
- [ ] 0.5 Gateway composition (#20): reproduce whether a tagged process can reach
  an allowlisted model host directly, bypassing the proxy. Do not fix yet.
- [ ] 0.6 Drop behaviour (#14): harness a tagged connection to a non-allowlisted
  host; record errno and time to failure per filter verdict.
- [x] 0.7 Attribution (#15, #19): document how tags are keyed and inherited;
  reproduce the launchd-detached gap as a test.
- [x] 0.8 Gap table: for each of the 23 problems, Exists / Partial / Missing with
  file references.

**Human checkpoint:** review the audit; decide the open questions it surfaced.

## Phase M0 — Make failure visible (#1, #2, #3, #4, #18)

- [ ] M0.1 Denial record schema: event id, time, agent, session id, project,
  resource, operation, verdict, and a reason code from a fixed enum
  (`not_on_allowlist`, `rule_denied:<id>`, `protected_resource:<class>`,
  `unattributed_process`). Print a rule name only when a rule matched.
- [ ] M0.2 Activity store: bounded local store the menu-bar app reads; filters by
  agent, session, project, allowed, denied, pending.
- [ ] M0.3 Notifications: on by default; grouped by session, resource and reason
  with a count; rate-capped; menu-bar badge fallback when notification permission
  is declined.
- [ ] M0.4 Measured health (#18): each extension heartbeats active state, loaded
  policy hash, latest grant generation, attribution counters; gateway reports
  routed requests; the app shows configured versus observed.
- [ ] M0.5 Sanitized denial query (#2): `kai why <event-id>` and
  `kai denials --mine`; a caller sees only its own session; no grant capability.

**Acceptance:** with both walls on, the October 22 denial produces a correct
grouped notice and Activity entry, and health shows both walls enforcing with
matching policy versions.

## Phase M1 — Make legitimate access possible (#9, #10, #11, #15, #19, #22, #23)

- [ ] M1.1 Design note `docs/design/grants-v2.md`: grant schema (subject session,
  project, resource, operation, scope, expiry, creator, generation); protected
  storage; propagation and maximum revocation latency; fallback when identity is
  uncertain. **Human checkpoint:** approve it.
- [ ] M1.2 Session identity: session id assigned at a known agent's root exec,
  keyed on its audit token; inherited by children; project recorded at root exec.
  Unverified lineage, including launchd-detached processes, gets no session and no
  session grants.
- [ ] M1.3 Authenticated approvals (#23): grants created only from Kai's UI by
  explicit user action; the grant interface checks the caller's code-signing
  requirement and refuses agent-tree callers; CLI grant commands refuse tagged
  callers; every change audited.
- [ ] M1.4 Deny-then-retry (#22): immediate response, asynchronous request; notice
  offers This task (10 min), This session, This project, Keep blocked; no "Always
  allow".
- [ ] M1.5 Risk tiers: policy-defined non-overridable classes (private keys, cloud
  credentials, Kai policy and grants) never offer approval.
- [ ] M1.6 Expiry and revocation: enforced within the M1.1 bound; test expiry
  mid-task.
- [ ] M1.7 Safe pause (#11): 15-minute and 1-hour pause with auto-resume and
  notice; full disable moves to Settings with a persistent warning.

**Acceptance:** October 22 replay plus the concurrent-session, detached-child,
spoofed-session, grant-forgery and expiry tests pass on live extensions.

## Phase M2 — Make secure defaults usable (#5, #6, #7, #13, #20, #21)

- [ ] M2.1 Profile format: versioned, read-only files in the app bundle per agent:
  signing identity, core channels, optional channels, resource classes; named
  hosts over wildcards.
- [ ] M2.2 Claude Code profile from Anthropic's network requirements and the
  storage classes.
- [ ] M2.3 Cursor, Codex, Gemini profiles: verify against installed versions;
  record the version verified.
- [ ] M2.4 Optional channels UI: per-agent toggles for updates, registries,
  plugins, MCP.
- [ ] M2.5 MCP discovery (#13, #21): watch MCP config paths; record file, time and
  writing process; show as pending review; never write policy automatically.
- [ ] M2.6 Gateway routing guarantee (#20): model hosts reachable only via the
  proxy path; fix the 0.5 reproducer.
- [ ] M2.7 Baseline workflow tests per agent under full enforcement with no broad
  exceptions.

**Acceptance:** Claude Code, Codex and Cursor pass baseline workflows with both
walls on.

## Phase M3 — Make it pleasant (#2, #8, #12, #14, #16, #17)

- [ ] M3.1 Observe-first onboarding (#8), stating plainly that observe mode
  protects nothing.
- [ ] M3.2 Setup wizard (#16, #17): walls, Kai's macOS approvals, accurate
  explanation of macOS folder prompts, agent detection, profile review, mode
  choice.
- [ ] M3.3 Permission manager (#12): who has what, how long, granted by whom;
  one-click revoke.
- [ ] M3.4 Agent-readable diagnostics: e.g. a Claude Code hook that checks
  `kai denials --mine` on a network or file error and surfaces the reason.
- [ ] M3.5 Faster failure (#14): apply what 0.6 found achievable.

**Acceptance:** a new user installs, onboards and finishes normal tasks without
repeatedly opening Settings.

## Release gate

Every row of the release test matrix (in `docs/walls-ux-evaluation.md`) passes on
real, signed system extensions. Until then, Kai is not described as
Community-release ready.

## Human-only steps

- Apple Developer enrolment, Endpoint Security entitlement, Developer ID
  certificate, notarization credentials.
- Approving system extensions, Full Disk Access and network filtering in System
  Settings.
- `systemextensionsctl developer on` and reduced SIP, on a dedicated test Mac only.
- Approving the Phase 0 audit and the M1.1 grants design note.
- Any decision under Open questions in the evaluation.
