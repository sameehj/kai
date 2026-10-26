# v1 Step 3 — one authenticated control path (M1.3)

## Goal
Policy, grants and pending changes have exactly one writer: the signed Kai app.
The `kai` CLI stops writing those files and becomes a client of the app's XPC
service. The caller is identified by its **audit token** (never a pid), verified
against Kai's code signature + Team ID, then checked for an agent ancestor.

## What changed

**Transport + decision (C, testable):**
- `src/control.c`
  - `kai_control_service_start()` — the app hosts a libxpc Mach-service listener
    (`io.github.sameehj.kai.control`). Per message it reads the peer's audit
    token, calls `kai_audit_token_identity`, refuses anyone not validly signed
    on Team `KD446VDTM2`, computes the caller's agent-tree status, and runs the
    request.
  - `kai_control_service_apply(op, argv, caller_pid, caller_is_agent, …)` — runs
    the already-trusted refuse/pending/apply logic and returns a message.
  - `kai_control_request(op, argv, …)` — the CLI client; sends the command and
    relays the result, or fails with a clear "open Kai" message if the service
    isn't reachable. It never writes the store.
- `src/proc.c` `kai_audit_token_identity()` — validate a caller's dynamic
  signature (anchored to Apple) from its audit token; return Team ID, signing
  id, pid. All SecCode use stays in C.
- `src/manage.c` / `src/grant_cli.c`
  - `kai_cmd_policy` / `kai_cmd_grant` now route **writes** to the service
    (`kai_control_request`); reads stay local. Direct file writes remain only
    under the test seam.
  - caller-pid override so the audit records the real client's process tree;
    `kai_grant_dispatch` applies the service's agent verdict.
- `src/policy.c` `kai_path_is_policy_store()` — policy + grants + pending (NOT
  the registry, which the extension writes).

**Storage wall (Swift):** `StorageClient.authorize()` now lets ONLY the app
process (`signing_id == io.github.sameehj.kai`) write the policy store, in every
mode — replacing the per-binary "kai-signed" write exemption. A kai-signed CLI
run from a human terminal is blocked from writing policy too, so there is a
single path. The wider control store still bars agent-tree writers.

**App:** `KaiBarApp` starts the service at launch and registers the
control-service LaunchAgent (`ControlServiceAgent`, SMAppService) that advertises
the Mach name so the CLI can reach it. Plist:
`Sources/LaunchAgents/io.github.sameehj.kai.control.plist`, copied to
`Contents/Library/LaunchAgents/`.

**Build guard:** `control.c` `#error`s if `KAI_PRODUCT_BUILD` (set on the app
target) and `KAI_TEST_DIRECT_POLICY` are set together; `make check-no-test-seam`
greps the xcodegen configs.

## Tests
- **Unit (tests/storage/run_storage_tests.c → test_control_service) — PASS:**
  policy store excludes the registry; an agent-tree caller is refused; a human
  loosening is held pending and NOT applied; a human tightening applies at once;
  an agent cannot create a grant through the service.
- **Compile:** C (client + listener + handler) builds clean; app builds with the
  CLI write-logic linked in.

## Live "done when" (NEEDS YOU — the signed app + System Settings)
These can't run without the signed, registered app:
1. Mach registration works: `kai policy set …` from a terminal reaches the
   service (not a direct write), and with the app closed it fails with the clear
   "open Kai" message.
2. U0 bypass battery still blocked: direct `./kai`, stripped-env, `launchctl`
   detaching, `osascript`, and a **raw write** to the policy store from any
   non-app process are all denied.
3. A loosening `kai policy set` from a human terminal is HELD pending (confirm in
   the app), a tightening applies, an agent-tree `kai policy set` is refused.

## Flagged for the live/signing gate
- The LaunchAgent/SMAppService **Mach registration** is unverified here; it needs
  a signed build and may need iteration (the security decision itself is in C and
  unit-tested — only reachability depends on this).
- The **CLI must be signed with a different signing id** than the app
  (e.g. `io.github.sameehj.kai.cli`) so it can't match the policy-store app-only
  check. Confirm at signing time.
- `xpc_connection_get_audit_token` is libxpc SPI (declared in control.c); stable
  and standard for this pattern, but note it for review.
