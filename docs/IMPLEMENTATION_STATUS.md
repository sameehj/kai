<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# KAI — Implementation Status (whole-codebase evaluation)

A grounded, honest map of what Kai actually does today: what is implemented and
verified, what is coded but unproven at runtime, what is partial, and what is
missing. Produced from a read-only audit of the source (v `0.1.0`); every claim
is tied to code. **A feature existing in code is not a security guarantee** —
the status column says how far each one is actually established.

Companion docs: `docs/WALLS.md` (wall design), `docs/THREAT_MODEL.md`,
`docs/SECURITY-VALIDATION.md`, `docs/ESCAPES.md` (known bypasses),
`docs/SCOPED_APPROVALS.md` (the approvals design + its own Phase-0 audit),
`tests/storage/RESULTS.md` (live wall results).

### Status legend
- **V — Verified in code**: logic present and correct on inspection; pure-C
  paths are additionally exercised by offline unit tests.
- **U — Runtime-unverifiable from source**: correct-looking, but depends on a
  signed/approved OS extension, the kernel, or a live agent that can't be
  exercised by reading code. Needs a live test to confirm.
- **P — Partial**: implemented with explicit gaps.
- **M — Missing / not implemented**.

---

## 0. The headline: what is actually ON by default

Kai ships deliberately conservative. Out of the box, the active protections are
the **agent hooks** and (once the user turns them on) the two walls. Policy
switch defaults (`src/manage.c` SWITCHES):

| Switch | Default | Meaning |
|---|---|---|
| `secrets` | `redact` | redact detected secrets in scanned text |
| `on_prompt_secret` | `block` | a secret in a prompt is blocked |
| `on_file_secret` | `ask` | reading a file with secrets → ask (Claude) / block (others) |
| `on_upload` | `block` | uploading a file with secrets is blocked |
| `injection` | `warn` | prompt-injection patterns warn, don't block |
| `egress` (network wall) | `log` | **allow-all + record**; not blocking until set to `block` |
| `storage` (storage wall) | `off` | **no file control until set to `log`/`block`** |
| `max_scan_bytes` | `2000000` | scan cap |
| `audit_context` | `on` | record redacted excerpts in the audit log |

So by default the **network wall logs but doesn't block**, and the **storage
wall is off**. The hooks (secret redaction, injection warning, upload blocking)
are the always-on baseline. The two OS walls are opt-in and, for storage,
additionally gated by an Apple entitlement (below).

---

## 1. Agent hooks (the always-on baseline) — `src/hooks.c`, `src/install.c`

| Capability | Status | Notes |
|---|---|---|
| Claude Code hooks: UserPromptSubmit, PreToolUse (Bash/Read/Edit/Write/… + `mcp__.*`), PostToolUse, Stop | V (install) / U (live) | `install.c:133-137` |
| Cursor hooks: beforeReadFile, beforeShellExecution, beforeMCPExecution, beforeSubmitPrompt, `failClosed:true` | V / U | `install.c:150-194` |
| Codex hooks: PreToolUse, PostToolUse, UserPromptSubmit | V / U (Codex silently skips untrusted hooks; status can't detect) | `install.c:362-402` |
| Fail-closed: hooks `exit 2` when Kai is missing — **only** for PreToolUse + UserPromptSubmit (not Stop/PostToolUse, by design) | V | `install.c:76-95` |
| `ask` only possible for Claude (its own prompt); Cursor/Codex get block | V | `hooks.c:608-611, 738-752` |
| Install is JSON-surgical (marks `_kai`, backs up, de-dupes); uninstall strips Kai entries, refuses unreadable files | V | `install.c:214-294` |

**Inherent limit (by design):** hooks are advisory — they only see tool calls
the agent runtime actually routes through them. A tool that isn't hooked, or a
direct syscall, bypasses the hook layer entirely. That is *why* the OS walls
exist.

## 2. Text scanning — secrets, injection, redaction — `src/scan.c`, `src/policy.c`

| Capability | Status | Notes |
|---|---|---|
| Secret detectors: private key blocks, AWS access/secret, GitHub/GitLab/Slack tokens, Stripe, Google/OpenAI/Anthropic/OpenRouter keys, JWT, DB-URL-with-password, password/assign, generic secret assignment | V | `policy.c:74-93` |
| False-positive suppression (placeholders `<...>`, `xxxx`, `changeme`, markdown, example values) | V | `scan.c:120-194` |
| Redaction for logs (`kai_redact_for_log`) and `kai redact` | V | — |
| Prompt-injection detection (patterns → `warn` by default) | V (detect) / P (action is warn-only) | `policy.c` injection rules |
| Custom `term` / `rule` / `rule_injection` user rules | V | `manage.c:653-755` |
| Scan size bound (`max_scan_bytes`, default 2 MB) | V | — |

All of §2 is pure C and covered by `tests/run_tests` (106 checks, 0 failures).

## 3. Storage wall (Endpoint Security) — `app/macos/Storage/`, `src/storage.c`, `src/scan.c`

| Capability | Status | Notes |
|---|---|---|
| AUTH events: OPEN, CREATE, RENAME, UNLINK, TRUNCATE, LINK, CLONE, EXCHANGEDATA, COPYFILE, READDIR | V (code) / U (enforcement) | `StorageClient.swift:62-68`; AUTH only under `KAI_STORAGE_ENFORCE` |
| Deny agent opens of protected paths; Kai self-exempt by **code signature** (team, non-adhoc) | U | `StorageClient.swift:226-231, 358-389` |
| Always-protected, un-exemptable control paths (`~/.kai`, `.claude/settings.json`, `.cursor/hooks.json`, `.codex/*`) checked before the allow-list | V | `scan.c:241-315` |
| Public CA trust bundles no longer blocked (fixed) | V | `policy/default.policy` allow lines |
| Audit now records the **file path** (not just the rule) | V | `StorageClient.swift` v12 |
| In-handler stage profiler (lock-free, default off) | V | `storage_prof.c` |
| **Everything fails OPEN** (unresolved path / nil client / classification fail / policy load fail → allow) | V | by design, `main.swift:9-11` |
| Read vs write **not distinguished** (`write` param ignored) | V | `storage.c:26` |
| Path handling is **lexical only** — no realpath/lstat; symlink/hardlink/inode not resolved | V/M | `util.c:120-153` |
| **Live policy reload** (reloadPolicy called only at start; no re-poll) | P/M | `StorageClient.swift:102` |
| ES deadline overrun protection (margin measured, not enforced) | M | — |
| Ships enforcing | **M — gated** on Apple Endpoint Security entitlement; default `off` | `WALLS.md:171` |

Live results: `tests/storage/RESULTS.md` — v10/v11 breadth **17 PASS / 1 FAIL**
(the FAIL is the launchd-detached read, §11) / several NOT-TESTED.

## 4. Network wall (NEFilterDataProvider) — `app/macos/Network/`, `src/net.c`

| Capability | Status | Notes |
|---|---|---|
| Socket-level content filter; decision in C (`kai_egress_endpoint_allowed`) | V / U | `FilterDataProvider.swift:42`, `net.c:144-166` |
| Allowlist by hostname+subdomain / IPv4+IPv6 / CIDR / `:port` | V (pure C) | `net.c:16-166` |
| TLS SNI (cleartext) + HTTP Host extraction | V (offline `kai sni`) | `net.c:222-279` |
| Loopback always allowed | V | `net.c:139-153` |
| Agent-scoped via process-tree walk; pid+pidversion cache | V / U | `FilterDataProvider.swift:174-194` |
| Live log + block enforcement | U (live-only; `run_network_check.py`) | — |
| **Fail-OPEN** everywhere (no token / non-agent / nil policy / ext down → allow) | V | `FilterDataProvider.swift:44-49, 208-228` |
| Live policy reload (2 s mtime poll on hot paths) | V / U | `FilterDataProvider.swift:148-164` |
| DNS (port 53) always allowed | M (intentional) | `WALLS.md:87-88` |
| **Exfil to an *allowed* host** (destination-only; no content inspection) | M (by design; gateway is separate) | `WALLS.md:95-97` |
| QUIC/UDP 443 (drop-to-force-TCP in block; unseen in log); ECH | P / M | `:63-67` |
| Post-handshake / mid-connection inspection | M (flow forgotten after first bytes) | `:90, 218-221` |

## 5. Agent attribution — `src/proc.c`

| Capability | Status | Notes |
|---|---|---|
| Match by exe-glob / team-id / argv-glob (first match; user lines before builtins) | V | `proc.c:132-153` |
| Ancestry walk keeps descendants (git/gh/ssh/python) classified | V | `proc.c:155-175` |
| Recognized: Claude Code, Codex CLI, Cursor (+ Gemini) | V | `policy.c:100-113` |
| Network cache pid+pidversion (reuse-safe); storage cache pid-only, invalidated by EXEC/FORK/EXIT | V / U | — |
| `responsible_audit_token` delegation (storage only) | U | `StorageClient.swift:245-249` |
| **Weaknesses:** argv-match is forgeable; exe-glob evadable by rename; team-id C path not `cs_valid`-checked; launchd re-parenting sheds attribution | V (as weaknesses) | §11 |
| Per-session identity at wall level | M (session exists only in hooks for audit) | `hooks.c:395-397` |

## 6. Policy / IPC / audit log — `src/policy.c`, `src/manage.c`, `src/audit.c`

| Capability | Status | Notes |
|---|---|---|
| Plaintext DSL policy at `$KAI_POLICY` or `<home>/policy`; only CLI/`init` write it | V | — |
| **No authenticated IPC** — all actors coordinate via the shared `~/.kai` file tree | V | grep: no XPC/mach |
| Atomic policy write (validate-by-reparse → tmp → fsync → rename) | V | `manage.c:225-255` |
| Hash-chained JSON audit log (0600, flock, rotation); root exts chown to user | V | `audit.c:97-204` |
| `~/.kai` tamper protection | P — tamper-**evident** (hash chain), not tamper-**proof**; real-time defense is the storage wall (off by default) | `audit.c:206-243` |
| Policy propagation: network ext re-reads in ~2 s; storage ext only at start | V / P | §3 |

## 7. AI gateway — `src/gateway.c`

| Capability | Status | Notes |
|---|---|---|
| Local loopback-only HTTP proxy (8787); fixed upstreams (OpenAI/OpenRouter/Anthropic) | V | `gateway.c:47-51, 493-497` |
| Scans + redacts JSON string values in **requests**, blocks ≥ BLOCK with an SDK-shaped 403; fail-closed 503 on bad policy | V | `gateway.c:275-294, 420-459` |
| Responses pass through untouched (SSE preserved) | V (request-only by design) | `gateway.c:316-354` |
| Wired/enforced by default | M — manual opt-in only (set base URLs + `kai gateway &`); live-agent testing pending | `README.md:41`, `WALLS.md:120-123` |

## 8. Browser extension + native bridge — `integrations/browser/`, `src/native.c`, `src/browser.c`

| Capability | Status | Notes |
|---|---|---|
| MV3 extension: scans composer/paste on 9 AI chat sites; shadow-DOM redact/send/edit panel; fail-closed | V (code) / U (live sites) | `content.js`, `background.js` |
| Native-messaging host: length-framed JSON; `ping`/`scan`/`decision`; least-privilege (scan+log only); fail-closed on bad policy | V | `native.c` (tested: `tests/browser/`) |
| `make chrome-zip` packaging + permission guard (only nativeMessaging+storage) | V | `scripts/package-chrome.py` |
| Chrome Web Store publication | P/M — unpublished (`KAI_STORE_EXTENSION_ID` empty); a store build can't reach the host yet | `CHROME_STORE.md:26-28` |

Self-labelled **experimental / developer preview**.

## 9. CLI — `src/main.c`, `src/manage.c`, `src/report.c`, `src/health.c`

| Capability | Status | Notes |
|---|---|---|
| Surface: init, hook, install/uninstall, scan, redact, log, policy, status, gateway, agent-of, sni, report, storaged, version | V | `main.c:211-241` |
| `status --json`: policy + per-agent (installed/detected/working via live deny-probe) + chrome ping + audit intact | V / U (probes) | `manage.c:81-151`, `health.c` |
| **No network/storage wall status in CLI** (app-only) | M | §9 |
| `report <id>`: writes a local Markdown file + prints a GitHub issue URL; **nothing sent until the user opens it** | V | `report.c:172-268` |
| `policy set/add/remove/show` with parse-before-write + built-in-rule exemption guard | V | `manage.c` |
| `storaged`: dev monitor via `eslogger`, **never blocks** | V (monitor) | `storaged.c` |

## 10. macOS app / UI — `app/macos/Sources/KaiBar/`

| Capability | Status | Notes |
|---|---|---|
| Menu bar: health, stats, per-agent toggles, per-wall toggles, recent events, needsApproval warning | V | `MenuView.swift` |
| Activate/deactivate extensions (storage truly deactivates; network disables the filter) | V / U | `StorageWall.swift`, `NetworkWall.swift` |
| State via audit-log polling (2 s) + CLI status (10 s) + live NEFilterManager + storage-log scrape | V | `AppModel.swift` |
| **No interactive approval UI** (allow/allow-once); only informational block notices + the agent CLI's own `ask` prompt | M | §Scoped Approvals |
| StorageWall UI doesn't refresh true state at launch (shows Off even if running) | P | `StorageWall.swift:23` |
| Spoofing: agent-influenced path/excerpt text is displayed (redacted for secrets; agent name allowlisted); no Kai approval dialog to spoof yet | P | — |

## 11. Scoped Approvals (new) — `src/grant.c`, `docs/SCOPED_APPROVALS.md`

| Capability | Status | Notes |
|---|---|---|
| **M0 grant engine**: HMAC-signed grants, JSON store, load, match, `kai_storage_decide` gate; builtin paths never grantable; identity bound to pid+pidversion; enforcement-time expiry; exact realpath resource; weak-identity→one-shot | **V (offline, this change)** | 20 unit tests pass |
| M1 CLI (`kai grant list/revoke/create`) | M (next) | — |
| M2 bounded storage reload | M (prerequisite) | — |
| M3 app approval UI + key management | M | — |
| M4 live wiring behind `KAI_STORAGE_ENFORCE` | M | — |
| M5 live validation | M (human-gated) | — |

---

## Cross-cutting known gaps / bypasses (carried, not fixed)

1. **launchd-detached read — demonstrated FAIL (release blocker).** A process
   re-parented to launchd sheds agent attribution; the network wall then allows
   its traffic and the storage wall can't attribute its reads. `WALLS.md:56-58`.
2. **Exfil to an allowed host** — the network wall is destination-only; a secret
   already read can be POSTed to an allowed domain. Storage and network are
   independently enforced *by design* precisely because of this.
3. **DNS (port 53) always allowed** — DNS-tunnel exfil is not stopped.
4. **Inherited file descriptors** — ES authorizes `open()`, not reads on an
   already-open fd; a non-agent opener passing an fd isn't catchable.
5. **Lexical path handling** — the storage engine matches path strings, not
   resolved inodes; symlink/hardlink nuances depend on what the kernel reports.
   (Scoped Approvals' own matching uses realpath to avoid widening a grant.)
6. **Fail-open walls** — both walls allow when the extension is down or policy
   won't load. Safe for availability, not fail-closed.
7. **Storage policy reload is start-only** — live policy/grant changes need a
   wall toggle until M2 wires a bounded re-read.

## Test posture — what proves what

- **Offline unit tests** (`make test` → `run_tests` 106/0, `run_storage_tests`
  incl. 11 profiler + 20 grant checks): prove the **pure-C engine** (policy,
  scanning, egress, SNI, attribution logic, grants). They **predict** decisions;
  they do **not** prove live OS enforcement.
- **Live manual** (`tests/storage/breadth_probe.py`, `tests/network/run_network_check.py`):
  the only evidence of real ES/NE enforcement; must run from an agent-attributed
  process (the breadth probe now prints its own attribution).
- **Gateway/native** e2e shell suites exist (`tests/gateway/`, `tests/browser/`).
- A Scoped-Approvals test counts as passed only when the **live extension**
  enforces it, not when the simulator predicts it.

## Maturity / release-readiness (Community edition)

- **Shipping-quality:** scanning engine, agent hooks + fail-closed install,
  audit log, CLI, native-messaging bridge, policy management.
- **Opt-in / experimental:** network wall (verified in log mode; block has
  documented gaps), AI gateway (manual, request-only), browser extension
  (unpublished).
- **Gated / off by default:** storage wall (Apple entitlement pending; off by
  default) — the richest recent work (v12, profiler) but not shipping-enforced.
- **In progress:** Scoped Approvals (M0 engine landed; UI/CLI/live wiring next).

*Generated from a source audit; update the status columns as live validation
and milestones land. Nothing in producing this document changed enforcement
code or touched a running extension.*
