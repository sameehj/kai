<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai Security Plan v1.0 — Frozen

Oct 31, 2026 · Sameeh Jubran

**This is the one authoritative spec for Kai's security work and its order of work.** Every other plan in this
repository keeps its specs and tests but not its build order (see "Repository document map" at the end).

This plan is frozen as of October 31, 2026; from here the work is implementation and evidence, not redesign. The architecture is frozen; the threat model is not. A new bypass becomes a test case and a fix, never a new architecture or release plan. Kai protects critical assets regardless of who acts, applies more restrictions when it knows an agent is acting, and reports exactly what the operating system enforced.

## Design invariants

Two invariants are permanent; every feature and claim must respect them.

1. **Asset protection never depends on attribution.** Critical assets must not depend on successful AI-agent attribution for their baseline protection. Attribution may strengthen or customize restrictions, but failing to recognize an agent must never silently remove host-wide protections. An unidentified process never becomes a trusted one.
2. **Claims match enforcement.** Kai may say an action was **Stopped** only when the enforcing component confirms denial before completion. It may say **Restored** only after verifying the restoration. Everything else is **Observed**, with any remediation attempt and its uncertainty recorded separately.

One limit on the second invariant: denying one operation doesn't prove no equivalent bypass exists. A claim about a whole class of attack needs coverage testing.

## Architecture: two independent layers

Kai makes one enforcement decision per operation from two policy layers, and reports each layer's coverage separately.

| Layer | Applies to | Controls | Preventive mechanism |
| --- | --- | --- | --- |
| 1. Host-wide asset protection | Every process: Claude, Cursor, VS Code, Terminal, unknown executables | Writes to `authorized_keys`, LaunchAgents and Kai's control store; reads of a small key set, limited to named readers | Endpoint Security authorization only |
| 2. Agent-aware restrictions | Processes confidently attributed to an agent | Workspace access, network destinations, commands, session-scoped approvals | Network Extension (egress), Endpoint Security (files), hooks (tool calls) |

- **Observe is not protect.** A Layer 1 rule in observe mode, or enforced by detect-and-remediate, doesn't protect the asset. Only Endpoint Security authorization, or another mechanism proven preventive, establishes the boundary.
- **Write and read protection differ.** The host-wide write baseline is small and explicit, with a named writer allowlist. Universal read denial of cloud credentials would break normal developer work, so read rules name each legitimate reader and the operation.
- **Layer 2 never relaxes Layer 1.** A session grant can widen what an agent may do, but not lift a host-wide asset rule. Only owner-authenticated break-glass access can, every time.

## Corrections accepted

Six points from the review stand, and the earlier claims they correct are retracted.

- **No latency promises.** "Undone within moments" was a claim, not a measurement. Nothing is promised until the replay produces numbers.
- **Restoring a LaunchAgent doesn't undo what it ran.** For persistence, the honest outcome is usually *Observed, with cleanup recorded*, not *Restored*.
- **Three user-facing outcomes, not one verb:**
  - **Stopped**: denied before it happened.
  - **Restored**: restoration verified, not just attempted.
  - **Observed**: recorded, not prevented or reversed.
  - A failed remediation shows a warning, never *Restored*.
- **`eslogger` is a bridge, not the foundation.** Native Endpoint Security stays the target. The observer is a separate, replaceable evidence source.
- **Acquisition figures.** Palo Alto's 10-Q puts Koi's purchase consideration at $231 million, completed April 14, 2026; the February agreement was $300 million including replacement awards. Portkey was agreed at $140 million. The earlier ~$400 million came from press reports. The acquisition question is deprioritized.
- **Hybrid file matching.** Inode matching alone misses replacement and newly created files, so matching combines path, case-folded name, object identity, parent folder and operation.

## Release tracks and exclusions

The Preview 1 → Preview 2 → Preview 3 → Private Pilot progression stays; the Chrome extension leaves every track.

- **Removed:** the Chrome extension, its native-messaging host, `kai install chrome`, the Chats coverage matrix (A5b), and the Gate A item that depends on it. Any Chats claim leaves the README, installer and `kai status`.
- **Preview 1 ships hooks only** and never waits on the entitlement-free experiment.
- **Excluded until the replay proves otherwise:** any claim of file protection without Endpoint Security authorization; any "network protected" status that hasn't passed the allowed-HTTPS exfiltration row.
- **Still deferred:** OAuth/PKCE, signed grants or policies, DPoP, RFC 9421, an MCP proxy, automatic updates, Teams features.

## The frozen plan (the order of work)

Each item names the release it blocks, so the experimental responder can never delay an honest hooks-only preview.

| Priority | Work | Release requirement |
| --- | --- | --- |
| P0 | Truthful wall health and policy initialization (G5) | Mandatory |
| P0 | Documented enforcement coverage and attribution behavior | Mandatory |
| P0 | Remove Chrome integration and dependent claims from Track A | Mandatory |
| P0 | Stop `release.yml` publishing on preview tags; traceable build | Mandatory before tagging Preview 1 |
| P0 | Letter-case and folder-rename bypasses in hooks (G4, G14): fix, or list in ESCAPES and COVERAGE | Mandatory before tagging Preview 1 |
| P1 | Hybrid path and object matching in the walls | Mandatory before claiming native file protection |
| P1 | Host-wide policy for critical assets (Layer 1) | Mandatory for the full-protection edition |
| P1 | `eslogger` observer | Optional experiment, not a Preview 1 dependency |
| P2 | Three-outcome UI: Stopped, Restored, Observed | Mandatory before presenting remediation outcomes |
| Gate | Eight-combination adversarial replay | Mandatory for each related security claim |

## Replay gate

The Oct 30 attack runs in four configurations against two process origins, eight primary combinations, each with detached-child variants. Use harmless fixtures only: a fake key, a local test endpoint, a synthetic extension-host child.

| Configuration | Hooks | Network enforcement | File security |
| --- | --- | --- | --- |
| A. Preview 1 | Yes | No | Hook observations and denials only |
| B. Network only | Yes | Yes | No OS file enforcement |
| C. Network + observer | Yes | Yes | Detect-and-remediate prototype |
| D. Full native | Yes | Yes | Endpoint Security authorization |

**Process origins:** a Cursor extension host (tagged) and a VS Code extension host (untagged). Each origin also runs a child that outlives its parent.

**Acceptance matrix**, recorded per combination:

| Attack action | Required evidence |
| --- | --- |
| Modify `authorized_keys` | Denied before write, or restoration verified |
| Create persistence | Denied before activation, or activation and cleanup outcomes recorded |
| Open reverse tunnel | Connection denied before establishment |
| Send recon data | Bytes prevented from leaving, not merely destination detected |
| Launch detached child | Child correctly attributed after reparenting |
| Exfiltrate through an allowed HTTPS endpoint | Explicitly tested; protection not assumed |
| Act through an unknown process | Handled by Layer 1 and the unknown-process rule, not trusted |
| Act through a privileged helper | Result recorded; any gap goes in ESCAPES.md |
| Read cloud credentials | Pre-read denial only where Endpoint Security enforces it |
| Restart Kai or disable a wall | Health moves to an accurate degraded status |

Record OS denials, observed events, remediation results, coverage gaps and wall-health failures against the commit. A failed row blocks its own claim, not necessarily the whole release.

**Result classes.** Every row in every combination gets exactly one:

| Result | Meaning |
| --- | --- |
| PASS | The required behavior was verified |
| FAIL | A claimed or required control failed |
| NOT COVERED | The configuration has no mechanism for that boundary (expected, not a regression) |
| INCONCLUSIVE | The evidence can't settle the result |

No overall pass rate is reported. FAIL blocks the claim; NOT COVERED feeds the public coverage matrix.

**Tamper resistance** (full-protection gate only). An untrusted process tries to:

| Attempt | Required evidence |
| --- | --- |
| Disable or unload an enforcing extension | Prevented where macOS allows; otherwise health goes Degraded at once |
| Stop or unload the privileged helper | Same |
| Replace or move Kai's policy, grants or helper configuration | Denied by Layer 1 |
| Impersonate Kai's XPC control interface | Refused by audit-token and signing checks |
| Abuse the privileged helper to act for it | Refused, or recorded in ESCAPES.md |

Degraded status is required when enforcement stops, but it doesn't replace preventing unauthorized shutdown where feasible.

**Evidence record.** The harness writes one machine-readable record per run (JSON), with these fields:

- commit SHA, macOS version, Kai component versions
- configuration (A to D) and process origin (Cursor, VS Code, detached child)
- test action, expected result, observed result
- OS enforcement evidence (the denial event or its absence)
- result class

Releases are compared by diffing these records, not by reading reports.

## Installation friction

The number of approval prompts is a hypothesis until measured on a clean Mac. Apple states that `eslogger` needs superuser execution and Full Disk Access for its responsible process, but the prompts a user actually sees depend on how the helper is installed, which executable TCC holds responsible, existing permissions and the deployment method.

- [ ] Measure a successful install, end to end, on a clean Mac
- [ ] Measure each rejected permission and the recovery path
- [ ] Measure uninstall, and confirm no helper or permission is left behind
- [ ] Count prompts per configuration (A to D) and add the result to the usability gate

## Sources

- [Palo Alto Networks Form 10-Q, quarter ended April 30, 2026](https://www.sec.gov/Archives/edgar/data/0001327567/000132756726000015/panw-20260430.htm)
- [Palo Alto Networks Form 10-Q, quarter ended January 31, 2026](https://www.sec.gov/Archives/edgar/data/1327567/000132756726000005/panw-20260131.htm)
- Kai walls audit, `docs/audit/walls-audit-2026-10-30.md` (not in this repository; see the map below)

---

## Repository document map (migration, Oct 31, 2026)

How the migration plan's document map applies to what is actually in this repository. Each document below
carries a header line pointing here; sections that conflict with this spec are marked superseded, not deleted.

| Document | Keeps | Superseded |
| --- | --- | --- |
| `docs/security/RECONCILED-PLAN.md` | Architecture, invariants, priorities, replay gate | — |
| `docs/DESIGN.md` | MVP design record | Its build order; current state is the header note |
| `docs/IMPLEMENTATION_STATUS.md` | The whole-codebase evaluation | "What's next" ordering |
| `docs/ROADMAP.md` | The long-term list | Its ordering |
| `docs/OVERVIEW.md` | The full overview (the pre-v0.2 README) | Chats / Chrome extension sections; any build order |
| `docs/SCOPED_APPROVALS.md`, `docs/design/grants-v2.md` | Grant design and specs | Milestone order (M1–M5) |
| `docs/M5_VALIDATION_PLAN.md` | Live validation steps | Its schedule |
| `docs/agents-and-sessions-plan.md` | Session and permission specs | Build instructions order |
| `docs/walls-action-plan.md`, `docs/walls-usability-sprint.md`, `docs/walls-ux-evaluation.md` | Problem inventory, specs and tests | Phase and sprint order |
| `docs/audit/walls-audit.md` (Oct 23) | Gap table and evidence | Its order of work |
| `docs/WALLS.md`, `docs/RUNTIME.md`, `docs/THREAT_MODEL.md` | Mechanism descriptions | Anything claiming protection beyond what the replay records show |
| `docs/ESCAPES.md`, `docs/COVERAGE.md` | Generated as today | Gain rows from replay results, NOT COVERED included |

**Not in this repository** (they live in the owner's documents): the Oct 30 walls audit
(`walls-audit-2026-10-30.md`, gaps G1–G14), the v1 plan, the preview release plan v2.1 and the first-release
experience spec v2.1. Their build orders are superseded by this spec as well; code comments that cite them
("spec v2.1 A.x") keep pointing at their specs, not their order.
