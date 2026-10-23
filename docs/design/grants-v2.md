<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Grants v2 — design note (M1.1)

**Status: awaiting human approval (the M1.1 checkpoint).** No v2 code is written
until this is approved. It extends the grant engine already built in M0–M4
(`src/grant.c`, `src/approval_store.c`) rather than replacing it.

## What already exists (v1, offline, not live)
- HMAC-signed grants; `kai grant create` is UNSIGNED and never honored; signing
  happens only in the app on a UI click (`Approvals.swift`).
- Identity bound to **pid + pidversion**; exact realpath resource; operation
  (read/write/connect); scope process|one-shot; enforcement-time expiry; atomic
  durable one-shot consume; immediate revocation; generations; audit lifecycle.
- Storage-only; wired into `StorageClient` behind `KAI_STORAGE_ENFORCE` with
  async **deny-then-retry**. **No network grants. No session concept.**

## What v2 adds (the M1 gaps)
1. **Session identity (#19).** A `session_id` assigned at a recognized agent's
   **root exec**, keyed on that root's **audit token** (pid+pidversion), recorded
   with the project path at root exec, and inherited by children. A process whose
   lineage to a known agent root can't be verified (including launchd-detached)
   gets **no session** and therefore **no session grants** — it falls to deny.
2. **Project binding (#10).** The project is the agent root's working directory
   **captured at root exec** (not re-read later, so a `cd` can't move a grant). A
   grant may be scoped to `session`, `project`, or `oneshot` — never a bare
   directory name.
3. **Network/egress grants (the Oct 22 fix).** Extend grants to a `connect`
   operation against a destination (`host` or `host:port`), honored by the egress
   filter: a not-on-allowlist drop for an agent with a matching valid grant
   becomes allow-for-the-window. Same signed-grant model; no new trust path.
4. **Safe pause (#11).** A time-boxed pause of a wall (15 min / 1 h) with
   auto-resume, distinct from a full disable (which stays in Settings with a
   persistent warning). Pause is a signed, expiring state the extension honors.

## Grant schema v2 (extends `kai_grant`)
Add fields; keep all v1 invariants. The HMAC covers the **new** canonical form
(so a v1 record can't be replayed as v2, and vice-versa — version the canonical
string).

```
v1 (unchanged): id, created_utc, expires_utc, pid, pidversion, agent,
                strength, resource, op, scope, approved_by, hmac
v2 additions:   grant_version (=2)
                session_id      (bind to one verified agent session; "" = none)
                project         (realpath captured at root exec; "" = any)
                dest_kind       (path | endpoint)   // endpoint => network grant
```
- A **storage** grant: `dest_kind=path`, `resource`=canonical path, `op`=read/write.
- A **network** grant: `dest_kind=endpoint`, `resource`=`host[:port]`, `op`=connect.
- Matching adds: `session_id` must equal the subject's current session (when the
  grant is session-scoped); `project` must match (when project-scoped); identity
  still bound to pid+pidversion for process scope.

## Session identity — mechanics and honest limits
- **Source:** the storage ES extension sees every `NOTIFY_EXEC`. When a known
  agent root execs, mint a `session_id` (random) keyed to its audit token, and
  record `(session_id, project=cwd-at-exec)`. Children inherit via FORK/EXEC
  lineage (same mechanism as today's agent tag).
- **Fallback (fail-closed):** if the subject's session can't be resolved
  (detached, reparented, unknown lineage), it has no session → session- and
  project-scoped grants do **not** apply → deny. Only a strictly process-scoped
  grant (pid+pidversion) could still match, and detached processes lose that too.
- **Open limit:** this is attribution-strength-bound. A launchd-detached process
  still sheds identity (the standing FAIL); v2 does not fix that — it fails
  closed for grants in its presence.

## Propagation & max revocation latency
- **Storage:** the approval store reloads policy+grants on a debounced timer; the
  engine also checks expiry at decision time. Target bound: **revocation visible
  within the reload debounce (≈2 s)**; expiry is enforcement-time (immediate).
- **Network:** the egress filter already re-reads policy on a ~2 s mtime poll;
  network grants ride the same path. Target bound: **≈2 s**.
- Both: a one-shot is durably consumed (marker) so it can't survive a reload.

## Protected storage & the request/grant invariant
- Grants live under `~/.kai/grants` (control path, hard-deny to agents) and are
  only honored with a valid HMAC under `~/.kai/approval.key` (app-held). **An
  agent can request (write a pending/unsigned record), never grant.** The CLI
  grant-create stays unsigned; signing is UI-click-only; approver auth and
  read-only-vs-policy-changing interface separation are M1.3.

## Non-overridable risk tiers (M1.5)
Policy-defined classes that **never offer approval**, regardless of grants:
private keys & cloud credentials (`~/.ssh`, `~/.aws`, …), and Kai's own policy /
grant store / key (`~/.kai`). These are the builtin/un-exemptable set already
enforced by `kai_rule_is_builtin`; v2 keeps them non-grantable.

## Deny-then-retry for both walls (M1.4)
- **Storage:** deny the AUTH event immediately, enqueue a pending request, agent
  retries after approval (already built).
- **Network:** drop the flow, enqueue a pending request; the agent's retry (new
  flow) is allowed once the grant exists. The notice offers **This task (10 min)
  / This session / This project / Keep blocked** — no "Always allow" (that's a
  deliberate Settings action).

## Open questions for approval
1. **Session-id source:** is minting on the storage extension's `NOTIFY_EXEC`
   the right anchor, or should the agent root be identified differently (e.g.
   the hook layer passing a session id)? Reliability of audit-token lineage
   across re-exec is the risk.
2. **Network "this task" window:** length (proposed 10 min) and granularity
   (per `host` vs per `host:port`)? One MCP task opens several connections.
3. **Project identity:** cwd-at-root-exec — acceptable, or do we need a stronger
   project key (git root? a project marker file)?
4. **Pause semantics:** does a paused wall fail *open* (no enforcement) for the
   pause window — and is that acceptable, given it's user-initiated and
   time-boxed with a visible warning?

---

**On approval**, M1 proceeds: M1.2 session identity, M1.3 authenticated
approvals, M1.4 deny-then-retry (network side), M1.5 risk tiers, M1.6 expiry/
revocation across both walls, M1.7 safe pause — all offline/compile-checked,
with live acceptance (the Oct 22 replay, concurrent-session, detached-child,
spoof, forgery, expiry tests) deferred to a human-gated reactivation (M5).
