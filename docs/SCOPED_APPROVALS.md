<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# KAI Scoped Approvals — Audit & Design

**Status: DESIGN PHASE.** No enforcement code has been changed to produce this
document, and no running system extension was restarted, deactivated, or
modified. Everything below is either (a) a citation of code that exists today,
(b) a design proposal not yet implemented, or (c) an explicitly labelled
assumption or open question. Nothing here is a security claim about live OS
behaviour unless it says "verified live" with a reproduction.

Guiding principle: **KAI should give AI agents the freedom to work without
giving them the freedom to compromise the user.** A permission to *read* a
secret is never a permission to *transmit* it; storage and network stay
independently enforced.

---

## A. Current-state audit (Phase 0)

Grounded in a six-part read-only audit of the repo. Each capability is
classified:

- **V** — Implemented and *verified in code* (logic present and correct on
  inspection; pure-C paths are additionally offline-unit-testable).
- **U** — Implemented but *runtime-unverifiable from source* (correct-looking,
  but depends on the live signed extension / kernel-supplied data that cannot
  be exercised in this environment).
- **P** — Partially implemented.
- **M** — Missing.

The single most important structural fact, repeated because the whole design
rests on it:

> **There is no authenticated IPC anywhere in KAI.** Policy and audit are a
> shared file tree under `~/.kai`. The CLI, agent hooks, the menu-bar app, the
> network extension, the storage extension, and the gateway each link the same
> C engine and independently read/write those files. Coordination is entirely
> via the filesystem. (No XPC/NSXPC/mach/DistributedNotification exists;
> confirmed by grep.)

### A1. Storage / Endpoint Security enforcement

| Capability | Class | Evidence |
|---|---|---|
| AUTH event set (OPEN, CREATE, RENAME, UNLINK, TRUNCATE, LINK, CLONE, EXCHANGEDATA, COPYFILE, READDIR) | V (subscription) / U (enforcement) | `StorageClient.swift:62-68`, subscribed only under `#if KAI_STORAGE_ENFORCE` (`:175-176`) |
| Decision in `authorize()`; response via `es_respond_*` | V / U | `StorageClient.swift:358-389, 296, 304` |
| **Every failure mode is fail-OPEN (allow)** — unresolved/empty path, nil client, classification failure, nil/failed policy | V | `:373, 353-354, 369`; `scan.c:292`; policy load unchecked `:203` |
| **Read vs write NOT distinguished** (the `write` param is ignored) | V | `storage.c:26` `(void)write;`; `kai.h:150-153` |
| Kai self-exemption by code signature (CS_VALID set, CS_ADHOC clear, team `KD446VDTM2`), never by name | U | `StorageClient.swift:226-231` |
| Modes off/log/block actual behaviour (off=unsubscribe, log=audit+allow, block=deny) | V (off/log) / U (block deny) | `:179-183, 175-176, 377-384`; `kai.h:142-146` |
| **Live client calls `kai_path_protected` + inline mode check, NOT the unit-tested `kai_storage_open_allowed`** | V | `StorageClient.swift:374, 377-385` vs `storage.c` |
| `~/.kai` + agent-control paths protected *before* the allow-list, builtin/un-exemptable | V | `scan.c:250-287, 295, 303-305`; `manage.c:696-701`; `policy.c:404` |
| **Path handling is purely lexical — no realpath/lstat/readlink** | V | `util.c:120-153`; `scan.c:213-236` |
| rename-onto-protected / clone source+target gated (by path string) | V | `StorageClient.swift:330-343` |
| symlink / hardlink / inode resolution | **M** | lexical only (above) |
| **Live policy reload** (reloadPolicy only called at `start()`, `force:true`; no timer/watcher) | **M/P** | `StorageClient.swift:102, 199-210` |
| ES deadline overrun protection (margin is *measured* by the profiler, never *enforced*) | **M** | `StorageClient.swift:311-318`; `main.swift:9-11` |
| In-handler profiler is lock-free, zero-alloc, no hot-path I/O | V | `storage_prof.c:57-70`; export off-thread `:129-144` |

**Net storage posture:** the security value depends entirely on the live ES
extension being present, approved, granted Full Disk Access, built with
`KAI_STORAGE_ENFORCE`, and set to BLOCK — none of which is verifiable from
source, and **storage defaults to OFF** (`policy.c:55, 232`; `manage.c:332`).

### A2. Network wall

| Capability | Class | Evidence |
|---|---|---|
| `NEFilterDataProvider` socket-level content filter | V / U | `FilterDataProvider.swift:23, 29, 42`; `NetworkWall.swift:126-127` |
| Decision in C (`kai_egress_endpoint_allowed`); Swift only translates to allow/drop | V | `net.c:144-166`; `FilterDataProvider.swift:205-240` |
| Egress match: hostname+subdomain / IPv4+IPv6 / CIDR / optional `:port` | V (pure C, offline-testable) | `net.c:16-22, 43-59, 105-111, 144-166` |
| TLS SNI (cleartext ClientHello) + HTTP Host extraction | V (offline via `kai sni`) | `net.c:222-279`; `FilterDataProvider.swift:284-296` |
| Loopback always allowed (127/8, ::1, v4-mapped) | V | `net.c:127-142, 150-153` |
| Agent-scoped (process-tree walk), not host-wide | V (logic) / U (live tokens) | `FilterDataProvider.swift:44-46, 181-194`; `proc.c:155-175` |
| Live allow/drop enforcement (log + block) | U | only `tests/network/run_network_check.py` |
| **Fail-OPEN everywhere** (no token / non-agent / nil policy / ext down → allow); last-good kept on parse error | V | `FilterDataProvider.swift:44, 46, 49, 208, 228`; `NetworkWall.swift:72-75` |
| Live policy reload (2 s mtime poll on hot paths) | V / U | `FilterDataProvider.swift:148-164` |
| DNS (port 53) always allowed | **M** (intentional hole) | `:73`; `WALLS.md:87-88` |
| **Exfil to an *allowed* host** (destination-only allowlist, no content inspection) | **M** (by design; gateway is separate) | `WALLS.md:95-97, 99-123` |
| QUIC/UDP 443 (drop-to-force-TCP in block; unseen in log); ECH | P / M | `:63-67`; `WALLS.md:85-86` |
| Post-handshake / mid-connection inspection | **M** (flow forgotten after first bytes) | `:90, 218-221` |
| launchd-reparenting attribution | **M** (known gap) | `WALLS.md:56-58` |

**Why this matters for approvals:** the network wall **cannot** stop a secret,
once read, from being POSTed to an already-allowed host, and DNS is wide open.
This is the hard evidence for your rule #(storage≠network): a storage grant to
read a credential must never be treated as permission to send it.

### A3. Agent attribution (security-critical — treat as such)

| Capability | Class | Evidence |
|---|---|---|
| Match by exe-glob / team-id / argv-glob, first-match, user lines before builtins | V | `proc.c:132-153`; `policy.c:337-351, 424-429` |
| Parent/responsible ancestry walk (depth ≤64 to pid 1) keeps descendants (git/gh/ssh/python) classified | V | `proc.c:155-175` |
| Recognized agents: Claude Code, Codex CLI, Cursor (+Gemini) | V | `policy.c:100-113` |
| Network cache keyed by **pid+pidversion** (pid-reuse safe) | V | `FilterDataProvider.swift:174-192` |
| Storage cache keyed by **bare pid** (no pidversion); invalidated by EXEC/FORK/EXIT | U | `StorageClient.swift:37, 271-287` |
| `responsible_audit_token` delegated classification (storage only) | U | `StorageClient.swift:245-249` |
| Per-session identity at the wall level | **M** (session exists only in hooks for audit, `hooks.c:395-397`) | — |

**Attribution weaknesses (must fail closed where they bite):**

- **argv match is forgeable.** Any process can put `*/@anthropic-ai/claude-code/*`
  in an argv element and be *mis*-classified as an agent (`proc.c:143-145`).
  This is a false-*positive* risk — and for approvals it is dangerous in the
  other direction too: an attacker process could pose as "Claude Code" in an
  approval prompt.
- **exe-glob is evadable.** Copy/rename the binary outside the matched path and
  the agent sheds classification (false-negative).
- **Team-id C path is not signature-validated.** `read_team` (`proc.c:44-65`)
  trusts `kSecCodeInfoTeamIdentifier` without checking `cs_valid`/adhoc — unlike
  Kai's own-process check which does (`StorageClient.swift:226-231`).
- **Storage pid-only cache** can retain a stale verdict across a reused pid if an
  EXIT is missed/reordered; the pidversion the network side uses is available
  (`audit_token.val.7`) but unused by storage.
- **launchd re-parenting sheds attribution entirely** for the network wall (walk
  hits pid 1 → "not agent" → allow). Storage's responsible-token path is the
  only partial mitigation and it is the demonstrated FAIL below.

**Conclusion carried into the design (requirement #2):** the existing
attribution engine is **good enough to decide whom to *challenge*, but not good
enough to be the sole basis of a *grant***. Approvals must bind to the strongest
identity the OS gives us at the moment of the authorized action (audit-token
pid+pidversion, and code-signing where available), and must fail closed when
identity is weak (argv-only match, unsigned, or detached).

### A4. Policy / IPC / logging

| Capability | Class | Evidence |
|---|---|---|
| Policy = plaintext DSL at `$KAI_POLICY` or `<kai_home>/policy`; only CLI/`init` write it | V | `policy.c:269-466`; `manage.c:500-821` |
| Atomic policy write (validate-by-reparse → tmp → fsync → rename) | V | `manage.c:225-255` |
| Audit log = hash-chained JSON lines, `<kai_home>/audit.log`, 0600, flock-serialized, rotated 8 MiB | V | `audit.c:97-204` |
| Root extensions chown log back to console user (uid≥501) | V | `FilterDataProvider.swift:251-254`; `StorageClient.swift:401-408` |
| `~/.kai` tamper-protection | **P** (tamper-*evident* via hash chain, not tamper-*proof*; real-time defense is the storage wall, which is off by default) | `audit.c:206-243`; `scan.c:250-273` |
| Any grant / TTL / expiry / allow-once / revoke store | **M** | grep: none |
| Closest analogs: permanent `exempt <rule> <glob>` and `allow <path>` (no TTL); non-persisted "ask" | V | `policy.c:292, 398-406, 536-542`; `manage.c:683-711` |
| CLI subcommand scaffold to host `grant create/list/revoke` | — (addable, low-friction) | `manage.c:804-821` |

### A5. UI / notifications

| Capability | Class | Evidence |
|---|---|---|
| System-extension activate/deactivate (storage genuinely deactivates on "off"; network only disables the filter) | V / U | `StorageWall.swift:94-100`; `NetworkWall.swift:99-115` |
| **StorageWall UI never refreshes from the OS at launch** (shows Off even if running; only a `/tmp/kai-storage.log` scrape on a 3 s timer) | **P** | `StorageWall.swift:23, 63-78` |
| Existing interactive allow/deny = the **agent CLI's own** `on_file_secret: ask` prompt via hook JSON (Claude only; Cursor/Codex get deny) | V | `hooks.c:608-611, 738-752`; `policy.c:304` |
| Kai's own notifications = one-way `UNUserNotification` banners (no action buttons) | V | `AppModel.swift:381-405` |
| **No native Kai approval dialog; no push/blocking IPC extension→UI** | **M** | grep: no NSAlert/sheet/confirmationDialog for approvals |
| Menu bar shows agents/stats/recent/wall-toggles/needsApproval; no pending-approval queue or active-permission/session view | V (what exists) / M (approval UI) | `MenuView.swift` |
| Spoofing surface: agent-influenced path/excerpt text is displayed; redacted for secrets + agent name allowlisted; the `ask` *reason string* embeds an agent-influenced path and feeds a real allow/deny | **P** | `hooks.c:631, 748-749`; `MenuView.swift:241-242` |

### A6. Test posture & known gaps (from direct session work; corroborated by the tests audit pass)

- **Offline unit tests** (`make test`): `tests/run_tests.c` → 106 checks / 0
  failures this session; `tests/storage/run_storage_tests.c` → all pass incl. 11
  new profiler checks. These exercise the **pure-C engine** (policy, scan,
  egress, SNI, agent match, profiler). They **predict a decision; they do not
  prove live OS enforcement.**
- **Live, manual** (`tests/storage/breadth_probe.py`, `tests/network/run_network_check.py`):
  storage v10/v11 breadth = **17 PASS / 1 FAIL / NOT-TESTED** from an agent
  session with the wall active. The **one FAIL is the launchd-detached read**
  (responsible token resolves to launchd, not the agent) — a **demonstrated
  security failure and release blocker**, never a PASS.
- **Not yet measured:** the OFF baseline for storage overhead; per-stage ES
  timing (the v11 profiler is built for exactly this but not yet run live).
- **Zero coverage today** for: grants, expiry, revocation, concurrent-session
  isolation, confused-deputy approval, symlink scope-expansion of a grant. These
  are net-new and defined in §F.
- **Treat-as-passed rule:** a Scoped-Approvals test counts as passed only when
  the **active OS extension** enforces the intended result, not when the C
  simulator predicts it.

---

## B. Threat model

### Assets
1. **Credentials & secrets at rest** — SSH keys/`known_hosts`, cloud creds,
   `.env`/`*.pem`/`*.key`, token files.
2. **KAI's own integrity** — `~/.kai` (policy, audit log, and the new grant
   store), agent hook config (`.claude`, `.cursor`, `.codex`), the extensions.
3. **Confidentiality of secret *contents* in motion** — the network side.
4. **Human attention** — approval fatigue is a security asset; spend it rarely.

### Actors / trust tiers
- **T0 Human at the console** — the only approval authority. Identified by
  physical/local session, never by anything an agent can emit.
- **T1 KAI's own signed code** — extensions + CLI *when invoked by the human*.
- **T2 Recognized agent process** — Claude/Cursor/Codex identified by the
  strongest available signal (code-sign > exe path > argv).
- **T3 Untrusted / prompt-injected agent** — assume full control of its own
  argv, child processes, file writes within the user's uid, and the ability to
  invoke the CLI. **This is the adversary.**
- **T4 Unattributed process** (detached/launchd-reparented, or argv-forged) —
  identity cannot be trusted either way.

### Entry points / abuse cases the design must defeat
1. **Agent writes its own grant.** T3 can run `kai ...` and write files under
   the user's uid. A grant file under `~/.kai` is therefore **not proof of human
   consent** (requirement #1). → *Grants must be authenticated by something the
   agent cannot produce, not merely by file location.*
2. **Confused deputy.** T3 asks the human to approve action X ("read
   known_hosts to push to GitHub") but the grant, if coarse, lets it do Y (read
   the private key, read every `~/.ssh` file, or read it from a *different*
   process). → *Least-privilege binding (requirement #4).*
3. **Impersonation in the prompt.** T3 forges argv to appear as "Claude Code,"
   or stuffs misleading text into a path so the approval UI reads
   "approved by admin." → *UI shows only KAI-verified identity; unverifiable
   context is labelled as such (requirement #5, Phase 4).*
4. **Grant replay / lateral reuse.** A grant issued to PID A is used by PID B, a
   reused PID, a forked child, or a second concurrent session. → *Bind to
   pid+pidversion (and code-sign where available); fail closed on weak identity
   (requirement #2).*
5. **Delegation through an unattributed process.** T3 detaches the real work to
   a launchd job (T4) to both shed attribution *and* escape a PID-bound grant. →
   *A grant must not resurrect a detached process's access; detached = fail
   closed. Documented limitation if not fully closable.*
6. **Scope expansion via symlink/hardlink.** Approve `~/.ssh/known_hosts`, then
   symlink it to `id_rsa`. Because path handling is lexical (A1), a naive grant
   keyed on the path string would be bypassable. → *Grant scope must be checked
   against the resolved target, and must never cover `~/.kai`/control paths.*
7. **Exfil after legitimate read.** Human approves reading a secret; the agent
   then sends it to an allowed host (network wall can't stop this, A2). →
   *Storage and network stay independent; a storage grant carries no network
   privilege, and the approval text says so.*
8. **Revocation/expiry evasion.** Agent relies on the storage extension not
   re-reading policy (A1) to keep using an expired/revoked grant. →
   *Enforcement-time expiry check, not reload-polling alone (requirement #3).*
9. **Fail-open abuse.** Agent induces a policy-load failure or UI/IPC outage to
   get the default-allow behaviour. → *For a protected, agent-attributable op
   that is grant-eligible, absence of a valid grant = deny, never allow.*

### Trust boundaries (where a decision is actually enforced)
- **Only two real enforcement points exist:** the ES storage extension (file
  ops) and the NE network filter (flows). Hooks are advisory (they only see
  tool calls they're invoked for). The CLI and app are *not* enforcement points.
- **The approval authority (T0) must live on the KAI side of a boundary the
  agent cannot cross.** Given there is no authenticated IPC today, establishing
  that boundary is the central new work (§C).

---

## C. Proposed architecture

### C0. Non-negotiables (derived from the audit)
- The **approval authority is the menu-bar app running as the console user**,
  acting only on a **physical UI interaction** (a click in a KAI-owned window).
  An agent cannot generate that click. The *grant record* is persisted, but the
  *authority* is the human action, not the file (requirement #1).
- **Default-deny is preserved.** A grant can only *narrow* an existing denial
  for a specific (identity × resource × op × window). It can never un-protect
  `~/.kai`/control paths or override a builtin/un-exemptable rule
  (`kai_rule_is_builtin`), enforced by reusing the existing pre-allow-list check
  order in `kai_path_protected` (requirement #4).
- **Storage and network remain independently enforced.** A storage grant adds
  no egress permission and vice-versa.

### C1. Grant record (data model)
A grant is an append-only, signed record. Proposed fields:

```
id            ULID (sortable, unique)
created_utc   issue time
expires_utc   hard expiry (enforcement-time checked)
subject       { pid, pidversion, exe_sha256?, team_id?, agent_name,
                identity_strength: strong|medium|weak }
resource      canonical absolute path (realpath-resolved) OR egress endpoint
op            read | write | connect   (never "execute"; never a wildcard)
scope_kind    process  (pid+pidversion, dies with the process)
              | oneshot (single use, consumed on first match)
approved_by   "console-user"   (never an agent-supplied name)
approval_nonce random; the app proves liveness of the click
audit_ref     hash of the audit record for this approval
```

Notes:
- **No "task" scope.** macOS has no OS-level task boundary and the brief forbids
  trusting the agent's description of its task. The safe boundaries are
  `process` (lifetime of one verified PID) and `oneshot`. "Allow for this task"
  in the UI maps to **`process` scope** — honest, bounded, and not agent-claimed.
- `identity_strength`: **strong** = valid non-adhoc code signature (team/cdhash);
  **medium** = exe path under a known install location with pid+pidversion;
  **weak** = argv-only match or unsigned. **Weak identities are not eligible for
  anything beyond `oneshot`, and detached/T4 processes are never eligible.**
  (requirement #2.)

### C2. Where grants live and how they're trusted
- **Store:** `~/.kai/grants/` (one JSON file per grant) — already builtin-
  protected and un-exemptable, and chained into the audit log. But per
  requirement #1 **file presence is not consent.** Two-layer defense:
  1. **Write authority:** only the menu-bar app writes a grant, and only in the
     delegate callback of a real UI click. The CLI gets a `kai grant list` /
     `kai grant revoke` surface but **`kai grant create` is gated**: it is
     usable by the human, but a grant created via CLI is marked
     `approved_by: cli` and is **not honored by the storage/network engine for
     agent-attributable ops** unless it also carries the app's approval token
     (below). This directly answers "could an agent invoke the CLI to self-
     approve?" — it can write the line, but the engine won't honor it.
  2. **Approval token:** the app holds a per-boot random key (in memory +
     `~/.kai/approval.key`, 0600, created by the app, *protected as a control
     path*). Each honored grant carries an HMAC over its canonical fields. The
     engine (and extensions) verify the HMAC before honoring a grant. An agent
     cannot read `approval.key` (control-path protected by the storage wall) nor
     forge the HMAC. **Honest caveat:** this reduces to "the agent cannot read a
     file the storage wall protects" — i.e. it inherits the storage wall's own
     strength. If the storage wall is off, grants give no additional exposure
     because without the wall nothing was protected anyway. We document this
     dependency rather than claim independent cryptographic authority.
- **Analyzed attack — delegate the write through an unattributed process:** a T4
  process writing to `~/.kai/grants/` is still blocked by the storage wall's
  control-path protection (when on) and, lacking the HMAC, is not honored. When
  the wall is off, see the caveat above.

### C3. Authorization flow (enforcement-time)
For a protected, agent-attributable file op in the storage extension:

```
1. classify(process) -> agent? identity_strength?        (existing)
2. kai_path_protected(resolved_path)?  -> if not, ALLOW   (existing)
3. builtin/un-exemptable (e.g. ~/.kai)? -> DENY always    (existing; grants can't touch)
4. valid grant matching (subject identity, resolved resource, op, not expired,
   HMAC ok, scope not consumed)?                           (NEW)
     - yes -> ALLOW (and, for oneshot, consume)
     - no  -> if mode==BLOCK: request approval (async, below) then DENY-this-event
              else (log): record would-block
```

**Expiry is checked at enforcement time** against the record's `expires_utc`
(requirement #3), so an expired grant is dead even if the extension never
re-read the store. Revocation deletes/ tombstones the grant file; the engine
treats missing/tombstoned as no-grant.

### C4. Interactive approval without holding the ES callback (Phase 3)
**The ES AUTH callback must never block on the UI.** `main.swift:9-11` already
warns a slow handler stalls machine-wide I/O, and there is no deadline-extension
in the handler today. Therefore:

- **Asynchronous approval + bounded retry.** On a grant-eligible miss in BLOCK
  mode, the extension **responds DENY immediately** (fail-closed for the
  agent-attributable op) and **enqueues an approval request** (writes a
  `~/.kai/pending/<id>.json` request record; the app is already polling the KAI
  home every 2 s and can surface it). The human approves → the app writes the
  HMAC-signed grant → the agent's **retry** of the same operation now matches a
  valid grant and succeeds.
- This means the *first* attempt fails and the tool retries — acceptable for
  `git push` (git/ssh will surface an error the agent re-runs) and far safer
  than holding a kernel auth event open. We will measure the retry latency.
- **UI-unavailable / IPC failure / timeout:** the request simply expires
  unapproved; the op stays denied. **No path silently authorizes** (requirement
  #9). Unrelated non-agent processes are unaffected (they never entered this
  path).
- **Trade-off vs. synchronous hold:** synchronous (extend-and-wait) would make
  the first attempt "just work" but risks deadlock, deadline kills, and a wedged
  machine if the UI is gone. Async+retry is slightly worse UX on the first call,
  strictly safer, and degrades cleanly. **Recommended: async + bounded retry.**

### C5. Prerequisite: bounded storage policy/grant reload (requirement #3)
Before any *live* storage grant can expire/revoke correctly, the storage
extension needs what the network extension already has: a **debounced mtime
re-read** of policy *and* the grant store on its decision path (mirror
`FilterDataProvider.swift:148-164`). This is a small, **offline-unit-testable**
change to `StorageClient.swift` + the engine; it does **not** require
reactivating the live extension to develop or test the logic. Enforcement-time
expiry (C3) is the primary guarantee; reload is how revocation and new grants
*arrive*.

---

## D. UX proposal (Phase 4)

A native KAI approval card (new), shown only on a real grant-eligible BLOCK, in
a KAI-owned focusable window — never spoofable by agent text because every field
is KAI-verified:

```
KAI — Access Request
--------------------------------------------------
Claude Code wants to READ a protected file
  known_hosts  (~/.ssh/known_hosts)       [verified path]
to continue. KAI verified this request came from:
  Claude Code · PID 4411 · signed (Team …)   [identity: strong]

This grants reading THIS ONE FILE, by THIS process only,
for 5 minutes. It does NOT allow:
  · reading other ~/.ssh files (keys stay protected)
  · sending the contents anywhere (network stays enforced)

[ Deny ]   [ Allow once ]   [ Allow this process · 5 min ]
```

Rules:
- Only **KAI-verified** fields are shown plainly. Any agent-supplied context
  (e.g. "to push to GitHub") is shown **only if KAI can corroborate it** (the
  destination came from the network wall's observed SNI), else labelled
  "unverified, agent-stated." (requirement #5.)
- Three choices: **Deny**, **Allow once** (`oneshot`), **Allow this process ·
  N min** (`process` scope, short TTL). No "always," no silent broadening.
- **Identity gating:** a *weak* identity offers at most **Allow once**, and the
  card says "KAI could not strongly verify this process."
- **Menu-bar additions:** a *Pending approvals* section, an *Active grants*
  section (resource, op, process, countdown, **Revoke** button), and a
  recent-grants history. Also fix the StorageWall launch-refresh gap (A5) so the
  wall's true state is shown.
- **Approval fatigue:** routine safe ops never prompt (default-deny only prompts
  on a grant-*eligible* protected op the agent actually attempted). A `process`
  grant means one approval covers the whole push, not every file.

---

## E. Implementation plan (milestones, ranked by security value)

Each milestone has acceptance criteria; none changes the active extension until
a milestone explicitly gated on human authorization. **Do not restart/deactivate
the running extensions during design or during offline milestones.**

**M0 — Engine grant model + enforcement-time checks (offline, no extension).**
`kai_grant_*` in libkai: parse/serialize a grant, canonicalize+realpath the
resource, HMAC verify, expiry check, match against (identity, resolved path,
op). Extend `kai_path_protected`'s caller contract so a verified grant can turn
a *protected* verdict into allow — **but never for builtin/un-exemptable paths.**
*Accept:* unit tests green; a grant can never allow `~/.kai`/control paths; a
tampered/expired/HMAC-bad grant is ignored; symlinked resource resolves to the
true target before matching.

**M1 — CLI surface.** `kai grant list` / `kai grant revoke <id>`; `kai grant
create` writes a record but marks `approved_by: cli` (engine won't honor for
agents without the app HMAC). *Accept:* atomic writes; `--json`; agent-written
grant demonstrably **not** honored by the engine in tests.

**M2 — Bounded storage reload (offline logic).** Add the debounced mtime re-read
of policy+grants to `StorageClient.swift` + engine, mirroring the network path.
*Accept:* offline test of the reload/debounce logic; revocation reflected within
the bound; **enforcement-time expiry works even with reload disabled.**

**M3 — App approval authority + UI.** Native approval card; pending/active-grants
UI; `approval.key` (0600, control-path protected) + HMAC signing on real click;
fix StorageWall launch refresh. *Accept:* grant only written on a real UI click;
UI shows only verified fields; revoke works from the menu.

**M4 — Vertical slice wiring (code compiled, NOT activated).** Connect M0–M3 in
the storage extension behind `KAI_STORAGE_ENFORCE`; async request + bounded
retry. *Accept:* compiles clean into the sysext; offline/sim tests pass. **Live
activation is a separate, human-authorized step — not part of this milestone.**

**M5 — Live validation (human-gated).** Only after explicit authorization,
reactivate and run §F's adversarial suite live, including latency. Keep
`filter=none`, start in `log`, then `block`. **Stop and ask before this.**

Deferred (not in first release): team accounts, biometrics, cloud approval,
enterprise policy, per-session cryptographic identity, SSH operation-specific
authorization beyond the file-read grant (see Phase 2 below).

### Phase 2 — the SSH scenario, honestly scoped
Desired: Claude Code pushes a commit; KAI prompts; human approves a *narrow*
operation; push succeeds; grant expires; other `~/.ssh` stays protected; another
session can't reuse it.

What is **achievable** in the first release: a **`process`-scoped, short-TTL,
read grant for the specific files a push needs** — primarily
`~/.ssh/known_hosts` (and, if the user opts in on the card, the specific key
file). The push runs as a child of the approved agent PID, so it matches; a
second session (different pid+pidversion) does **not** match; the grant expires;
unlisted `~/.ssh` files stay denied.

What is **not** safely achievable yet, and is documented as a limitation:
- **True "approve the git-push operation, not the files."** There is no reliable
  OS binding from "an ssh subprocess" to "only this push to this remote"; ssh
  reads keys via normal `open()`, indistinguishable at the ES layer from any
  other read. We therefore grant **file-read scope**, not "git-push scope," and
  say so.
- **The launchd-detached bypass remains a demonstrated FAIL.** If the agent
  detaches ssh to launchd it sheds attribution (and thus any PID-bound grant) —
  which also means it can't *use* the grant, so this fails *closed* for the
  grant feature, but it remains an open problem for base attribution.

Never silently disable the storage wall to make git work.

---

## F. Adversarial tests (defined before implementation; disposable fixtures + fake creds only)

Offline (engine/sim) unless marked **[live]** (human-gated, M5):

1. **Unauthorized read denied.** No grant → protected read denied (block mode).
2. **Grant permits only the intended resource+op.** Read grant for file A does
   not allow read of file B, nor write of A.
3. **Unrelated protected files stay inaccessible** while a narrow grant is live.
4. **Expiry.** After `expires_utc`, the same op is denied **even if the store
   was not re-read** (enforcement-time check).
5. **Revocation.** `kai grant revoke` (or UI) → subsequent op denied within the
   reload bound; tombstone honored.
6. **Different process can't reuse.** Grant bound to pid+pidversion A; process B
   (incl. reused pid, different pidversion) denied.
7. **Forked/spawned child doesn't inherit** a `oneshot` grant; `process` grant
   covers only the exact subject identity, not arbitrary new pids.
8. **Concurrent Claude + Codex isolation.** A grant to one agent process is
   invisible to a concurrently running other agent.
9. **Missing UI / IPC failure fails closed.** Pending request with no approver →
   op stays denied; nothing silently authorized.
10. **Symlink cannot expand scope.** Grant for `known_hosts`; symlink it to a
    key → resolved-target check denies (resource realpath ≠ granted path).
11. **Agent cannot manufacture a valid grant** via logs, prompts, local IPC, or
    a CLI self-write (no app HMAC → not honored).
12. **Network exfil independently restricted.** With a storage read-grant live,
    an egress attempt to a non-allowed host is still blocked by the network wall
    (grants carry no network privilege).
13. **No regression.** Existing storage/network/hook protections and the 106-
    check unit suite stay green; breadth probe unchanged except the newly
    grantable case.
14. **Latency.** [live] Measure approval round-trip and the per-op grant-check
    overhead; grant-check must be O(small) and must not regress the OFF→ON
    workload deltas. Record avg/p95/p99.

Plus the forged-argv, renamed-exe, PID-reuse, re-parenting, agent-initiated CLI
write, confused-deputy, policy-reload-failure, and concurrent-grant-update cases
called out in requirement #6 — each mapped to tests 2/6/7/8/11 above and to new
negative tests.

---

## Proven vs. proposed vs. must-fix (requirement #7)

**Proven today (verified in code / verified live where noted):**
- Pure-C engine decisions (policy, path-protect, egress, SNI, agent-match) —
  unit-tested offline.
- Storage breadth: direct/symlink/child/rename/clone reads & creates of
  protected paths denied **[live, v10/v11]**; `~/.kai` strict-denied.
- Network log+block, loopback-allow, SNI/Host matching **[live per WALLS.md +
  run_network_check.py]**.

**Still assumption / runtime-unverifiable:**
- That the live ES/NE extensions enforce exactly as the engine predicts, under
  load, with correct deadline behaviour. (v11 profiler built to measure; not yet
  run live.)
- Storage pid-cache correctness under missed/reordered lifecycle events.

**Must be fixed before any Scoped-Approvals security claim:**
1. Bounded storage policy/grant reload (C5/M2) — else revocation/new grants
   don't reach a running wall.
2. Enforcement-time expiry (C3) — else expiry depends on reload.
3. Resolved-target (realpath) check for grant matching (M0) — else symlink
   scope-expansion (test 10) bypasses.
4. HMAC/approval-authority separation (C2) — else an agent CLI self-write =
   consent.
5. Identity strength gating + fail-closed for weak/detached identities (A3) —
   else forged argv / reparenting defeats binding.
6. The **launchd-detached FAIL** stays a documented, unresolved release blocker;
   Scoped Approvals must fail *closed* in its presence, not paper over it.

---

## Open technical questions (Phase 6 / F)
1. Is `audit_token` (pid+pidversion) reliably available for the responsible
   process in every storage AUTH event we gate, or only `process`? Grant binding
   strength depends on it.
2. Can we obtain a **cdhash/team** cheaply per-event for `identity_strength:
   strong` without blowing the ES deadline? (Caching by pid+pidversion.)
3. Exact first-attempt retry behaviour of `git`/`ssh` under an async
   deny→approve→retry — does it re-`open()` `known_hosts`, or cache the failure?
   Determines whether `oneshot` suffices or `process` is required.
4. Minimum viable HMAC/key story that doesn't itself become a new agent-readable
   secret — is `approval.key` under the storage wall enough, or do we need the
   app to hold the key only in memory and sign over a mach/unix socket (new
   authenticated IPC, larger scope)?
5. Can the network wall contribute a *corroborated* destination to the approval
   card (observed SNI) so the "to push to GitHub" line is verified, not
   agent-stated?

---

*This document is the Phase 0–1 deliverable. No enforcement code has been
changed and no live extension touched. Implementation (M0+) begins only on your
go-ahead, and live activation (M5) only on explicit, separate authorization.*
