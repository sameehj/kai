<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Scoped Approvals — M5 Live Validation Plan (NOT YET AUTHORIZED)

**This is a plan. Do not execute any step without explicit, separate human
authorization.** M5 is the first time grant enforcement runs under the live OS
extension; everything through M4 is compile-verified only. Activation, reload,
and live enforcement tests are gated.

`[YOU]` = human, in your own Terminal / the GUI / System Settings.
`[ME]` = the agent session, run only after you say go, and only for the
agent-attributable test steps.

## 0. Pre-flight & rollback (decide rollback BEFORE activating)

**Build (local, no activation):**
- `[YOU]` `make try-app-storage KAI_TEAM=KD446VDTM2` builds the embedded,
  signed storage extension at **v14** and the app (which now links libkai for
  in-process signing). Do not open/activate yet.

**Rollback paths (verify you can do each before step 1):**
1. **Primary:** menu-bar **Storage wall → Off** *deactivates* the system
   extension. The OS tears it down independently of the handler, so enforcement
   stops and file I/O proceeds (the wall fails open when absent). This is the
   fast rollback.
2. **Neutralize grants without deactivating:** delete `~/.kai/approval.key` and
   `~/.kai/grants/*`, then toggle the wall off/on. With no key the store is
   policy-only and no grant is honored — back to plain block behavior.
3. **Hard rollback:** quit Kai, `systemextensionsctl list` to inspect, uninstall
   the app; reboot clears a stuck sysext.
4. **Automatic backstop:** a hung handler misses the ES deadline and the OS
   kills the client → fails open. The async-deny design means the callback is
   never held, so this should not trigger.

Confirm rollback #1 and #2 work (toggle off, then on with no key) **before**
any grant test.

## 1. Activate (controlled)
- `[YOU]` Menu-bar **Storage wall → On**; approve the extension in System
  Settings → Login Items & Extensions → Endpoint Security; grant **Full Disk
  Access**. Keep policy `storage = block`, filter unset (`none`), profiler off.
- `[YOU]` Confirm version: `systemextensionsctl list | grep kai.storage` shows
  `0.1.0/14`.
- `[ME]` Baseline: run `tests/storage/breadth_probe.py` from this agent session;
  confirm the attribution banner says AGENT-ATTRIBUTED and the matrix matches
  v10/v11 (the launchd-detached case still **FAIL**).

## 2. Signing authorization (the human-consent boundary)
- `[YOU]` Trigger one approval via the menu (any pending request) so the app
  creates `~/.kai/approval.key`. Verify `ls -l@ ~/.kai/approval.key` is `0600`.
- `[ME]` Attempt, as the agent, to read `~/.kai/approval.key` — expect **denied**
  (control path, storage wall). Record separately as a security check.
- `[ME]` `kai grant create --resource <disposable> --pid $$ ...` then confirm the
  record shows `signed: no` and a matching protected op is **still denied**
  (unsigned grant not honored → no CLI self-approval).
- `[YOU]` Confirm an honored grant appears only after a real **button click** in
  the Kai window.

## 3. The SSH scenario — async-deny + bounded retry
Disposable only: use a throwaway key/known_hosts fixture, never real secrets.
- `[ME]` From the agent session, attempt a git push that needs `~/.ssh/known_hosts`.
  Expect: first attempt **denied**; a **pending request** appears in the menu.
- `[YOU]` Approve **Allow for this session** (process scope).
- `[ME]` Retry the push. Expect success. **Measure:** retry latency, and whether
  `ssh` re-`open()`s `known_hosts` on retry (the open question — determines
  whether one-shot suffices or process scope is required).
- `[ME]` After the grant's TTL, a fresh read is **denied** again.
- Record `kai log` shows `requested → approved → used` for this flow.

## 4. Expiry & revocation (bounded)
- `[ME]` With a short-TTL process grant active and allowing, `[YOU]` **Revoke**
  it in the menu. `[ME]` confirm the next read is denied within the reload bound
  (~2 s). `kai log` shows `revoked`.
- `[ME]` Let a grant expire; confirm deny, and that `kai log` shows `expired`
  (recorded at the next reload/cleanup, not at the instant of the TTL).

## 5. One-shot durability across real boundaries
- `[ME]` Approve **Allow once**; use it once (allowed), second attempt denied.
- `[YOU]` Toggle the wall off/on (extension restart). `[ME]` confirm the spent
  one-shot is **still** denied (durable `.used` marker).
- `[ME]` (crash test) while a one-shot decision is in flight, `[YOU]` `kill -9`
  the extension; on relaunch confirm the one-shot is not re-spendable (marker
  persisted before allow) — and note the single narrow window (crash between the
  atomic win and the marker write) as the documented residual.

## 6. Concurrent sessions isolation
- `[ME]` Run two agent sessions (e.g. Claude + Codex, or two Claude). Approve a
  grant for session A's process. Confirm session B (different pid+pidversion)
  is **not** allowed by A's grant.

## 7. ES deadline / UI-unavailable / fail-closed matrix
- `[ME]` Enable the profiler (`[YOU]` `touch ~/.kai/storage_timing`, toggle),
  run a workload, read `/tmp/kai-storage-timing.json`; confirm `deadline_margin`
  stays healthy and the callback is never held awaiting the UI. `[YOU]` remove
  the marker, toggle back.
- `[ME]` With the app quit (UI unavailable): a grant-eligible op → pending
  request written, op **denied** (nothing silently authorized).
- `[ME]` Fail-closed cases: no key, a corrupt grant file, a corrupt policy file,
  store unavailable → each must **deny**, never allow.

## 8. launchd-detached attribution — STILL A FAIL
- `[ME]` Re-run the launchd-detached read. It MUST remain a demonstrated
  **FAIL** / release blocker. Scoped Approvals fails *closed* in its presence (a
  detached process sheds the pid-binding and matches no grant), but base
  attribution still does not attribute the detached read. **Do not mark PASS.**

## 9. Performance
- `[ME]` ON vs OFF (identical operations, per the earlier correction — not
  total-minus-stages) with grants present; record avg/p95/p99 and the grant-check
  overhead.

## Deliverable
One acceptance report distinguishing **code-level / simulated / live** results,
the resolved issues, the remaining assumptions and the launchd bypass, the
policy-consistency and revocation guarantees, the one-shot durability guarantee,
grant-audit examples (disposable fixtures), and a go/no-go for shipping the
feature (likely gated off by default behind the key + enforce build).

**Again: do not run any of this without explicit authorization. Stop here.**
