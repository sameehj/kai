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
| Extension activation | macOS reported network v8 activated; storage v17 was installed but not listed active | Both signed extensions compile with enforcement enabled | Storage v17 active and enforcing |
| Measured health | `kai status` reported no network snapshot despite macOS showing v8 active | Storage code emits mode and grant generation | Policy hash, attribution counters, network heartbeat, matched Kai/macOS status |
| October 22 MCP replay | — | Network endpoint grant engine and UI compile | Deny → session grant → new-process retry succeeds with both walls on |

Current policy reported `storage=log`, `egress=log` during installation. Log mode
does not block. A live approval test requires the storage extension to be active
and Kai's measured status to agree with macOS. The M0.4 health gap and the
process-only grant scope remain release blockers. Do not interpret the signed
build or the passing `make test` suite as a successful live approval.
