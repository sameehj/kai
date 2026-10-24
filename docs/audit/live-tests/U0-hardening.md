<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# U0 hardening — policy-change protection (live test)

Hardens the U0 finding (a policy was switched to Block/block with no record of
who did it; `kai policy set/add/remove` did not refuse agents, and the signed
`kai` binary is wall-exempt). Four controls, layered:

1. **ES wall (defense in depth):** the Kai-signature exemption is withheld from a
   `kai` process running inside an agent tree when it WRITES Kai's control store
   (policy file, grant store, pending-policy). Reads stay exempt so an agent-run
   `kai denials`/`kai status` still works. Code: `StorageClient.authorize`,
   `kai_path_is_control_store` (`src/policy.c`).
2. **Loosening held pending (regardless of caller):** a change that REDUCES
   protection (a wall to a weaker mode, a new `allow`/`egress_allow`/`exempt`,
   removing a `protect`/`rule`/`term`/`agent`) is never applied by the CLI; it is
   written to `~/.kai/pending-policy/<id>.json` and must be confirmed by the user
   in the Kai app. TIGHTENING applies immediately. Code: `policy_commit_or_queue`,
   `set_loosens` (`src/manage.c`); confirm UI `PendingPolicyCard` /
   `GrantManager.applyPolicy` (`Approvals.swift`).
3. **Audit every change:** each attempted change is appended to the audit log
   with `source=policy`, `event=loosen|tighten`, `decision=pending|applied`, and
   a `detail` carrying the caller process chain and the caller's code-signing
   Team ID. Code: `policy_commit_or_queue` + `caller_context`.
4. **Agent callers refused outright:** `kai policy set/add/remove` still refuses
   an agent-attributed caller (`751edeb`), now via the testable
   `kai_policy_dispatch`.

## Unit tests (offline, deterministic) — PASS

`tests/storage/run_storage_tests.c` → `test_policy_pending` (and the existing
`test_policy_agent_refusal`). Run: `make test` (or compile `run_storage_tests`
with the CORE list). Asserts, all green:

- loosen `storage block->log` returns ok, live policy UNCHANGED, pending request
  written with the proposed change;
- tighten `secrets redact->block` applied immediately;
- `add allow` held pending (not in live policy); `add protect` applied at once;
- `remove protect` held pending (still in live policy);
- audit has a `pending` record and an `applied` record, each with `caller:` and
  `signed:`;
- an agent-attributed caller (`caller_is_agent=1`) is refused (exit 3), policy
  unchanged;
- all loosening requests were queued.

`run_tests` 106/0 and the rest of `run_storage_tests` remain green.

## Live test matrix (installed signed build)

Run against the reinstalled `/Applications/Kai.app` build with the storage wall
in **block**. Safety: the policy file hash is snapshotted before and verified
unchanged after; any pending request created by the test is removed afterward
(deleting a *request* file does not change protection).

A loosening change (`storage block -> off`) is used as the probe. Expected
outcome per attack path:

| # | How `kai policy set storage off` is launched | Attribution | Expected |
|---|---|---|---|
| A | directly in the agent shell | agent | **refused** (exit 3), policy unchanged |
| B | `env -i … kai policy set …` (stripped env), direct | agent (tree intact) | **refused**, policy unchanged |
| C | via `launchctl` (reparented to launchd) | none (detached) | **held pending**, policy unchanged |
| D | via `osascript` → Terminal.app | none (Terminal, not agent) | **held pending**, policy unchanged |

In every case the live policy must be **unchanged**. C and D additionally leave
a `~/.kai/pending-policy/*.json` the user would confirm or reject in the app.

### Results (filled after the live run)

- [ ] A direct — result:
- [ ] B stripped-env — result:
- [ ] C launchctl — result:
- [ ] D osascript — result:
- [ ] policy file unchanged (hash match) — result:
- [ ] audit shows the attempts with caller chain + signing identity — result:

## Known residual gap (honest limitation)

Controls #1 and #4 key on **attribution**; #2 gates only changes made **through
the `kai` CLI**. A process that fully defeats attribution (e.g. relaunched
through launchd so it has no agent ancestor) AND overwrites `~/.kai/policy` with
**raw file I/O instead of the `kai` CLI** is stopped by none of them: the ES
wall withholds the ~/.kai write only from attributed (or Kai-signed-under-agent)
processes, and a raw write never passes through the loosen classifier. This is
the pre-existing launchd-detached attribution gap (a documented release blocker).

**Open question for the human (decision needed):** make the ES wall permit
writes to the policy file / grant store ONLY from Kai-signed processes that are
not in an agent tree — denying all unsigned/raw writes regardless of
attribution. This closes the raw-write path but changes behavior for a
hand-edited policy (`vim ~/.kai/policy`) or any non-Kai tool while the wall is
on. Not implemented pending that decision.
