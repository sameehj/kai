<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Discrepancies between the authority documents

Rule: when two documents conflict, the higher one wins, and the conflict is written here. Order of authority for 0.3.0-preview.1:

1. `docs/security/RECONCILED-PLAN.md`
2. `docs/kai-redesign-2026-11-08.md`
3. `docs/security/decisions/2026-11-14-preview-security-scope.md` (Decision 3, three-state attribution, stays proposed)
4. `docs/security/incidents/README.md`
5. `docs/audit/walls-audit-2026-10-30.md`, `docs/kai-first-release-experience.md`

## D1. Three authority documents aren't in the repository (Nov 14)

`2026-11-14-preview-security-scope.md`, `incidents/README.md` and `kai-first-release-experience.md` don't exist on any branch or on this Mac. The release work followed the scope written into the release brief instead:

- the S1–S9 names it used (S1 covered entry points, S3 path equivalence, S4 settings rename, S7 false stops, S8 missing CLI or launcher, S9 ordinary work);
- the outcome words Stopped, Restored, Observed and Unprotected;
- the rule that attack replays run only in the VM.

Nothing from Decision 3 was implemented. **Action:** add the three files, then check `tests/regress/run_regress.py` against `incidents/README.md`.

## D2. The walls audit is `docs/audit/walls-audit.md`, and the attribution gap is §0.7

The brief cites `walls-audit-2026-10-30.md` and its §1. The file in the repository is `docs/audit/walls-audit.md` (Phase 0 audit, dated Oct 23, revised Oct 31), and the attribution findings are in its §0.7. Its header says RECONCILED-PLAN supersedes it, which matches the order above.

## D3. The Files wall depends on attribution; RECONCILED-PLAN says protection must not

RECONCILED-PLAN principle 1 (`RECONCILED-PLAN.md:15`): "Asset protection never depends on attribution."

`src/storage.c:56-58` lets every process that isn't attributed to an agent through ("The wall only ever constrains agents"). Audit §0.7 records the launchd-detached gap: a process that loses its agent ancestry isn't constrained.

This is recorded as an audit finding with no code change. The Files wall isn't in this release, and Layer 1 (host-wide) is a separate component in the plan. It is listed in `docs/ESCAPES.md` (code findings).

## D4. Phase 4 "MCP approval until revoked" before C3 revalidation

The redesign §3 replaces expiring MCP grants with an installation-level approval that is "revalidated when the executable or tools change". The brief removes `--for 1h` as the default now, but revalidation (C3) isn't built.

Followed: the brief (higher than nothing, and consistent with the redesign's direction). The approval holds until `kai undo`. The missing revalidation is listed in ESCAPES as `mcp-grant-sticky`.

## D5. Interpreter heredocs keep their path check

The brief asks Kai to stop judging heredoc bodies written to non-protected files. A body fed to `python3 -`, `node -` or a shell isn't written to a file: it is code that runs, and the hook can't know what it opens.

Followed: RECONCILED-PLAN's preventive stance. Those bodies are still checked, and a case keeps that true: S7-keep-k-3a68b9f2-py. The same source edit made with the Edit tool is judged by its target and passes (S7-k-3a68b9f2).
