<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai Walls — Phase 0 Audit

Oct 23, 2026. Read-only; **no behaviour was changed and no extension touched.**
Evidence is `file:line` into the current tree (v `0.1.0`, storage extension v15
staged). Per the action plan Rules, findings are labelled **Live** (observed on
the running extension), **Unit** (exercised by `make test` on this machine), or
**Not tested** (needs the live signed extension / a live harness).

> Headline correction up front: the architecture diagram's **"AI proxy
> (NE transparent proxy)" does not exist in the code.** There is only a manual,
> opt-in `kai gateway` (a loopback HTTP proxy). So by default no model traffic is
> routed to any gateway, and problem #20 is not a subtle bypass — there is simply
> no routing enforcement to bypass (grep for `NETransparentProxy`/`NEAppProxy`
> returns nothing).

## 0.1 Component map

| Component | Where | Entry point | Policy / grants |
|---|---|---|---|
| libkai (engine) | `src/*.c`, `include/kai.h` | pure C API | `kai_policy_load`; grants via `src/grant.c`, `src/approval_store.c` |
| Storage ES extension | `app/macos/Storage/StorageClient.swift`, `main.swift` | `es_new_client` → `handle()` (`:269`) | policy once at `start()`; grants via approval store (reload timer) |
| Network content filter | `app/macos/Network/FilterDataProvider.swift` | `handleNewFlow`/`handleOutboundData` | policy re-read on ~2 s mtime poll (`:148-164`) |
| NE transparent proxy ("AI proxy") | — | **absent** | — |
| Gateway | `src/gateway.c` | `kai gateway` (manual, loopback 8787) | policy per request |
| Menu-bar app | `app/macos/Sources/KaiBar/*` | SwiftUI; shells `kai`, polls audit log | reads via CLI JSON + file poll |
| CLI | `src/main.c`, `src/manage.c`, `src/grant_cli.c` | `kai <cmd>` | writes policy atomically; `kai grant` |
| Grant store | `src/approval_store.c` | `kai_approval_store_*` | rwlock snapshot, generations, reload, revoke |
| Hooks (L1) | `src/hooks.c` | agent hook events | policy fresh per invocation |
| Policy loader | `src/policy.c` | `kai_policy_load` (cached `kai_home`) | plaintext DSL at `~/.kai/policy` |
| Audit log | `src/audit.c` | `kai_audit` / `kai_audit_write` | hash-chained JSON lines, `~/.kai/audit.log` |

No authenticated IPC anywhere; all actors coordinate through the `~/.kai` file
tree (confirmed: no XPC/mach).

## 0.2 The five grant questions

1. **Can a live storage denial be approved and retried?** *Code exists, not
   live.* The grant engine (`kai_approval_store_decide`) and the deny-then-retry
   wiring (`StorageClient.swift`, behind `KAI_STORAGE_ENFORCE`) are built and
   **Unit**-tested; they are **Not tested** against the live extension. The
   approval UI signs grants on a UI click (`Approvals.swift`). So the mechanism
   is present end-to-end in code but unproven live — this is exactly the M1
   acceptance gap.
2. **Can a network grant be scoped to one session?** *No.* Grants and the
   approval store are **storage-only**. There is no network grant path and no
   "session" concept at the wall level — identity is per **pid+pidversion**, not
   a session id (`FilterDataProvider.swift:174-192`; `proc.c`). #19's "session"
   is Missing.
3. **Do expiry and revocation reach both running extensions, within what
   bound?** *Storage only, and not live.* The approval store enforces
   enforcement-time expiry and immediate in-memory revocation (**Unit**-tested,
   `run_storage_tests`), reload debounce ~2 s. The network wall has **no grant
   concept**, so nothing to revoke there. Live bound is **Not tested**.
4. **Can an agent-tree process forge or misuse a grant?** *Resisted in the
   engine; depends on the storage wall for the key.* A grant is honored only with
   a valid HMAC; `kai grant create` writes **unsigned** records (not honored);
   signing happens only in the app on a UI click. The signing key
   (`~/.kai/approval.key`) is defended against agents **only by the storage
   wall's control-path protection** (documented residual). So forgery is resisted
   **Unit**-level; the live property depends on the wall being on.
5. **Can the user complete the October 22 task without disabling a wall?**
   *Not today.* No network approval flow exists; the only path is editing
   `egress_allow` via the CLI. This is the primary M1 acceptance test and it
   currently fails.

## 0.3 Policy / grant refresh (divergence flagged)

- **Network filter:** re-reads the policy on a debounced mtime poll on its hot
  paths (~2 s), keeps last-good on a parse error (`FilterDataProvider.swift:148-164`).
  **Live-capable.**
- **Storage extension:** historically loaded policy **only at `start()`**
  (`StorageClient.swift:102`). The approval store added a debounced reload timer
  (for policy+grants); and v15 routes the protect decision through the store's
  reloaded snapshot. So storage reload is now wired **in code** but **Not tested**
  live. Divergence: network has always live-reloaded; storage did not until this
  work.
- **Grants:** the approval store reloads the grants dir on the same timer;
  revocation also updates the in-memory snapshot immediately. **Unit**-tested.

## 0.4 October 22 trace

- **`Rule: <host>` on a no-match (#3) — root cause found.**
  `FilterDataProvider.swift:237-249` builds `detail = "connection to <host> … is
  not on the allowlist"` and calls `kai_audit("network", agent, decision,
  target, detail)` where `target` is the host. But `kai_audit`'s **4th parameter
  is `rule`** (`kai_audit(source,event,decision,rule,detail)`), so the host lands
  in the `rule` field → the record reads `rule: innermonkeylabs.com` though no
  rule matched. Fix (M0): pass a reason code (`not_on_allowlist`) as the rule and
  keep the host in `target`/`detail`.
- **Paths denied when Claude lost its settings (#7).** From the launch error:
  `~/.claude/settings.json` and `~/Research/.claude/settings.local.json`, denied
  `EPERM` by the storage wall (both are builtin control paths). **Live-observed**
  (the user's launch). Fixed in **v15** (reads of hook-config paths now allowed;
  writes still blocked) — **staged, not live**.
- **Shipped defaults.** `policy/default.policy`: `egress log`, `storage off`,
  `secrets redact`, `on_prompt_secret block`, `on_file_secret ask`,
  `on_upload block`, `injection warn`; **zero `egress_allow` entries**.
  Confirmed. So default Kai blocks nothing; switching egress to `block` with an
  empty allowlist drops everything (#5).

## 0.5 Gateway composition (#20)

There is **no transparent proxy**, so model traffic is **not** redirected to the
gateway by default. The gateway (`src/gateway.c`) is a manual loopback HTTP proxy
the user must opt into by setting base URLs; it redacts request bodies and can
block. Consequence: a tagged process reaching an allowlisted model host connects
**directly** — "routing through the gateway" is not enforced anywhere. This is a
Missing capability, not a bypass of an existing control. **Not fixed (per plan).**

## 0.6 Drop behaviour to the calling process (#14)

The filter's verdict for a denied flow is `.drop()`. What that surfaces to the
caller (immediate `ECONNREFUSED`/`ECONNRESET` vs. a timeout) and how fast is
**platform-dependent and Not tested** here — it needs a live harness against the
signed NE extension. Observationally (Oct 22) Claude interpreted it as "no
internet," consistent with a silent drop/timeout rather than a clean refusal.
**Open question carried forward.**

## 0.7 Attribution (#15, #19)

- **Keying/inheritance.** Agent identity = exe-glob / team-id / argv-glob match
  (`proc.c:132-153`), with a parent/responsible ancestry walk
  (`proc.c:155-175`). Network caches per **pid+pidversion**
  (`FilterDataProvider.swift:174-192`); storage caches per **bare pid**,
  invalidated by EXEC/FORK/EXIT lifecycle events (`StorageClient.swift`).
- **Session identity (#19):** there is **no session concept** at the wall level;
  a "session" exists only in the hook layer for audit correlation
  (`hooks.c:395-397`). M1 must add an audit-token-anchored session id.
- **launchd-detached gap (#15):** a process re-parented to launchd loses the
  ancestry link → not attributed → the network wall allows it and the storage
  wall can't attribute it. Documented (`docs/WALLS.md:56-58`), reproduced in
  `tests/network/run_network_check.py`. **Still a demonstrated FAIL / release
  blocker.**

## 0.8 Gap table (23 problems)

Status: **Exists** (built, at least Unit-tested), **Partial**, **Missing**. "This
session" flags work done in the current Scoped-Approvals effort (offline).

| # | Problem | Status | Evidence / note |
|---|---|---|---|
| 1 | Blocks silent | Missing | notifications are one-way info banners (`AppModel.swift:381-405`), no actionable denial surface |
| 2 | Agent blames wrong cause | Missing | no agent-queryable denial record (`kai why`) |
| 3 | `Rule: <host>` on no-match | Missing (root cause found) | `FilterDataProvider.swift:237-249` passes host as `rule` |
| 4 | No activity view | Missing | menu bar shows recent blocks only; no filterable store |
| 5 | Block mode, empty allowlist | Missing | `policy/default.policy` has 0 `egress_allow` |
| 6 | No per-agent needs model | Missing | no profiles; built-in agent *identity* only (`policy.c:100-113`) |
| 7 | Storage blocks own settings | **Exists (offline, v15), not live** | `scan.c kai_control_read_allowed`, `StorageClient.swift openIsWrite` |
| 8 | Breakage found only after enforcing | Partial | `log` mode = observe, but no "suggested rules" / explicit enforce step |
| 9 | No way to approve one action | Partial (offline) | grant engine M0–M4 built + Unit-tested; **not live**, storage-only |
| 10 | Grants not project-scoped | Partial | bound to pid+pidversion+resource+op; no project/session binding |
| 11 | Walls off stay off | Missing | only global on/off; no pause/auto-resume |
| 12 | Permissions need file editing | Partial | `kai grant` CLI + a basic approval card exist; no full manager |
| 13 | MCP blocked | Missing | no MCP discovery or network grant |
| 14 | Agents retry blocked ops | Missing | no explainable failure; drop behaviour unmeasured |
| 15 | Attribution lost (launchd) | Partial | pid+pidversion keying exists; launchd gap unfixed (FAIL) |
| 16 | macOS dialogs confused with Kai | Missing | no onboarding/explanation |
| 17 | No first-run guidance | Missing | no wizard |
| 18 | Can't prove protection state | Partial | `kai status --json` has agent/hook/audit health but **no wall/extension-active/policy-version/grant-observed** signals (`manage.c`, `health.c`) |
| 19 | Grant → wrong session | Partial | identity is pid+pidversion, not an anchored session; no session grants yet |
| 20 | Exfil to allowed host / gateway routing | Partial/Missing | wall is destination-only (by design); gateway not wired (no transparent proxy) |
| 21 | Agent config manufactures requests | Partial | grant HMAC means config can't *grant*; MCP-config-as-request discovery not built |
| 22 | Consent inside ES callback | **Exists (offline)** | deny-then-retry + async pending implemented (`StorageClient.swift`), **not live** |
| 23 | Approvals forged | Partial (offline) | app-only click-only signing, grant store protected, audited; approver auth / interface separation partial |

## Summary for the human checkpoint

- The **grant half is substantially built but storage-only and not live** (#9,
  #22, #23 Exists offline; #10/#19 Partial — no session/project binding). The
  **network half has no grants at all** — this is the biggest gap for the Oct 22
  replay.
- The **feedback half is essentially unbuilt** (#1–#4, #18): no actionable
  notifications, no activity view, no agent-queryable reason, no measured wall
  health, and the misleading `Rule: <host>` record (root cause found).
- **Defaults are the other critical gap** (#5–#7): empty egress allowlist, no
  per-agent profiles; the own-settings block is fixed offline (v15) but not live.
- **Foundations:** the **AI proxy doesn't exist** (#20 reframed), the
  **launchd-detached attribution gap is still a FAIL** (#15), and there is **no
  session identity** (#19).

**Decisions needed (open questions):** whether egress was switched to block by
the user or shipped that way; the drop-behaviour measurement (#14, 0.6); the
network "this task" window length/granularity; notification grouping thresholds;
who maintains agent profiles; and confirmation of Codex/Gemini hosts + credential
paths. Live-only items (0.5 gateway routing, 0.6 drop timing, launchd replay)
require the signed extensions and are out of scope for this read-only phase.

*Phase 0 complete. No code changed. Awaiting the human checkpoint before M0.*
