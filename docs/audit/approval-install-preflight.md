<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Approval install preflight — October 23, 2026

Source commit for the signed build: **`bf1a3e1`** on
`fix/approval-key-and-ux`. Installed bundle: `/Applications/Kai.app`, storage
extension **0.1.0/17**, network extension **0.1.0/8**. The bundle was built with
`KAI_STORAGE_ENFORCE=1`; installation did not turn either wall to Block.

| Check | Live | Unit / build | Not tested |
|---|---|---|---|
| Grant subject identity | — | `src/grant.c` requires pid **and** pidversion; reused-pid unit test passes | A retry by a new agent child process |
| First approval key | Oct 23 v16 failure recorded: store opened without a key; approval was never used | v17 can install a first key on the reload worker; late-key unit test passes | v17 first-key approval against active ES extension |
| Grant created while running / after restart | — | Signed grant, reload, revoke and expiry unit tests pass | Both live extension cases |
| Control-path approval | Oct 23 approval for Codex `config.toml` did not work | v17 does not stage requests for builtin control paths; C matcher rejects them | Live read-only versus write-open trace under v17 |
| Extension activation | macOS now reports storage v17 **and** network v8 activated; Kai's fresh storage heartbeat reports **log, not enforcing** while policy is **block** | Both signed extensions compile with enforcement enabled | Storage v17 actually enforcing |
| Measured health | `kai status` has a fresh storage heartbeat but reports the mode mismatch; it has no network snapshot despite macOS showing v8 active | Storage code emits mode and grant generation | Policy hash, attribution counters, network heartbeat, matched configured/loaded modes |
| October 22 MCP replay | — | Network endpoint grant engine and UI compile | Deny → session grant → new-process retry succeeds with both walls on |

Current policy reported `storage=log`, `egress=log` during installation. After
the policy changed to `storage=block`, `egress=block`, macOS reported both
extensions active, but a fresh Kai storage heartbeat still reported `mode=log`
and `enforcing=false`. This is a real mismatch, not merely an absent snapshot:
`StorageClient.reloadPolicy(force:)` is only called at startup; its grant-store
timer reloads the policy snapshot without updating the extension's `mode`.
The network extension emits no health snapshot at all. **Stop the live approval
test until M0.4 reconciles these states.** The process-only grant scope is also
still a release blocker. Do not interpret the signed build or the passing
`make test` suite as a successful live approval.
