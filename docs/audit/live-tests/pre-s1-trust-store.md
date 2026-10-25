<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Pre-S1 fix 1 — trust-store resource class (live test)

## Audit investigation (requested)

From the real audit log, the denied writes to the Homebrew
`…/ca-certificates/cert.pem` file:

- **214 storage records**, 2026-10-23 19:10 → 2026-10-25 09:15.
- **All classified `claude`** (the agent). `codex` separately hit
  `…/anaconda3/ssl/cacert.pem`.
- All are `write-open` of a protected file, matched by the blunt `*.pem` secret
  rule, `rule: protected_resource`, decision `would-block` (log) then `block`.
- The records carry **no PID, no process chain and no session id**:
  `kai_denial_audit` stores only Kai's process *classification* (the agent
  name), and sessions do not exist yet — that is S1. So Kai can attribute these
  writes to the **claude** agent but has no per-session granularity until S1.

## The fix (engine)

A new **trust-store** resource class (`src/scan.c` `trust_store_path`),
classified before `allow`/`protect` so CA/trust files are not treated as a blunt
`allow` (writes would be free) nor a generic secret (writes would be
never-overridable):

- **Covers:** Homebrew `…/ca-certificates/…`, system `/etc/ssl/…` (and
  `/private/etc/ssl/…`), Homebrew OpenSSL `…/etc/openssl*/cert.pem`, the certifi
  `cacert.pem` bundle anywhere, and keychain `…/Keychains/*TrustSettings*`.
- **Reads allowed** for agents: `kai_control_read_allowed("trust-store") == 1`
  (TLS verification needs to read CA bundles).
- **Writes are OVERRIDE tier:** `kai_override_tier("trust-store") ==
  KAI_TIER_OVERRIDE`, and the class is not builtin, so the wall blocks the write
  but a user grant can override it — unlike Kai's own control store, which is
  `KAI_TIER_NEVER`.
- **Card text:** `kai_rule_explanation("trust-store")` = "changes which websites
  this Mac trusts". The storage wall now stages the approval request with this
  note and the tier; the decision card (`ApprovalCard`) shows "This changes which
  websites this Mac trusts — requested by <agent>." (The full tier-aware card
  with the writing tool's name lands in S6.)

## Automated tests — PASS (`make test`, exit 0)

`run_storage_tests` → `test_trust_store`: four CA-bundle paths and a keychain
trust-settings file are protected, classified `trust-store`, read-allowed,
override-tier, and grant-overridable; the control store stays never-tier and is
not trust-store; the card text explains the effect.

## Live test (human) — storage wall in Block, v19 active

1. **Read is allowed.** As the agent, read a CA bundle:
   `cat /etc/ssl/cert.pem` (or the Homebrew `…/ca-certificates/cert.pem`).
   - Expected: succeeds (no denial). Result: ______
2. **Write is blocked, with the trust-store card.** As the agent, try to append
   to a trust bundle, e.g. `echo "" >> /usr/local/etc/ca-certificates/cert.pem`.
   - Expected: denied; a decision card appears reading "changes which websites
     this Mac trusts" naming the writing tool, and offers **Override for this
     session** (it is override-tier, not never) — i.e. it HAS buttons, unlike the
     policy-file card. Result: ______
3. **Activity classifies it as trust-store.** The block appears in Activity / the
   audit log classified as the trust store (not a blunt `*.pem` secret).
   - Expected: trust-store classification shown. Result: ______

### Results (filled after the live run)

- [ ] 1 CA bundle read allowed —
- [ ] 2 trust bundle write blocked, override card with the effect text —
- [ ] 3 Activity shows trust-store classification —
