# Preview 1 contract: audit and results (experience spec v2.1, Part A)

October 29, 2026, branch `fix/ux-review-phase-a`. Evidence levels: **live** (a real agent session invoked Kai's hook and honoured the answer), **synthetic** (the agent's hook event, in its format, sent to the real `kai hook`, or a unit test), **untested**.

## 1. Audit: what existed before this pass

| Requirement | Before | Now |
|---|---|---|
| A.1 contract in README, installer, `kai status` | Partial: "guardrail, not a sandbox" wording; status said "Active"/"Protected"-style words | README top, `kai install` output and `kai status` carry the contract; status words are Checking / Partly checking / Not checking. The `.pkg` itself shows no text (no installer UI pages yet). |
| A.2 interception matrix | Partial: Observed / Denied / Bypass per operation | `docs/COVERAGE.md`: event, input available, stage, can block, bypasses, evidence (live or synthetic, dated) per agent and action, plus file writes, web fetch and a "Not checked" table |
| A.3 coverage report | Partial: installed + hook self-check + last use | Installed, Configured (current matcher; hooks switched off), Trusted (Codex: known only once Codex has run Kai's hook), Self-test (when), Live verification (when, version, changed since), checks per agent, OS enforcement "not included in Preview 1" |
| A.4 `kai demo` / `--live` | Missing | `kai demo` runs each installed agent's real hook command on a temporary fake secret; `--live` drives `claude -p` / `codex exec` and confirms from the log, using the agent's own session id. Cursor has no non-interactive mode: says so |
| A.5 messages | Partial: last round's wording said "blocked"; MCP pointed at a Kai app Preview 1 doesn't have | Fixed text, verb "stopped": what, why, the exact narrow command where Kai identified the target; "Kai couldn't tell exactly what this command sends…" otherwise; Kai's own settings: the spec's sentence. MCP without the app offers `kai allow-mcp` |
| A.6 CLI grants | Partial: host-level `kai allow` (too broad for the contract) | `kai allow-file --read/--write`, `allow-fetch`, `allow-mcp`, `allow-upload --to`, `block`, `undo`, `rules`. Agent + operation + target + expiry; canonical paths with device+inode (re-linked or replaced: no longer applies); uploads only when one simple curl/scp is read in full; refused inside an agent (stated as convenience); every output ends with the limit sentence |
| A.6b policy integrity | Missing (malformed/unreadable already failed closed, with log-style text) | Fingerprint on every Kai write; doctor reports malformed, unrecognized rule (named), changed outside Kai, missing; missing-after-Kai-wrote fails tool checks closed; the limit is printed |
| A.7 Chrome | Partial | Popup: "Checking N chats on …" (+ "not yet verified on these sites": the Chats matrix has no proven rows), "Today: N redacted before sending · N sent not checked", last event with Not a secret. The extension never notices anything after sending, and says nothing about it |
| Web fetch | Missing: WebFetch never reached the hooks | Claude Code's matcher includes WebFetch (new installs; `kai status` shows older installs as Partly checking). URL checked for secrets and `kai block` hosts; `on_fetch block` makes the fetch tool need `kai allow-fetch` |

## 2. A.8 mandatory tests

Live runs: `scripts/live-checks-preview1.sh` with Claude Code 2.1.312 and `kai demo --live`, on Sameeh's Mac, 2026-10-29, Kai in Preview mode (no app) with a throwaway Kai home. Grants in the live runs were made with the test-only binary (`tests/cli/kai-test`), because the real `kai allow-file` correctly refuses inside an agent and these runs were started from one.

| Test | Expected | Result | Evidence |
|---|---|---|---|
| Hook untrusted or disabled | Status shows not checking | Disabled (`disableAllHooks`): **Not checking**. Untrusted Codex: shown "Not checking … trust them in Codex (/hooks)" until Codex has run Kai's hook | Disabled: synthetic (CLI test). Untrusted: **untested live**, Codex already trusts Kai's hooks on this Mac |
| Agent edits Kai's policy file directly | "Changed outside Kai" | A real Claude Code session ran a script that appended to the policy; `kai doctor` reported changed outside Kai | **live** (check 5) + synthetic |
| Agent edits the policy and its fingerprint | Not detected; documents the limit | Not detected; doctor prints the limit | synthetic (unit) |
| Policy missing, unreadable, malformed | Tool checks fail closed with the doctor hint; prompt warns; doctor reports | Missing: a real session's Read was stopped with "Kai can't read its rules…"; all three states reported by doctor | **live** (missing, check 6) + synthetic (all) |
| Read grant on `.env`, agent uploads `.env` | Upload still stopped | Stopped | **live** (check 2) + synthetic |
| Grant on a path, file replaced by a symlink elsewhere | Grant doesn't apply | Doesn't apply (also when replaced by a new file) | synthetic (unit) |
| `kai demo` vs `kai demo --live` with an untrusted Codex hook | Self-test passes; live fails and says why | Self-test passed; live **passed**: Codex already trusts Kai's hooks here (session 01a18738). The "untrusted" message exists but wasn't exercised | **untested** for the untrusted case |
| Detached process reads a protected file | No claim; documented gap | Not claimed (status "Not checked", COVERAGE "Not checked"); the live run wasn't exercised (the model declined to start the detached script) | synthetic (coverage: script reads allowed) |
| Grant expires mid-task | Next action checked again | A 1-minute grant expired; the next real read was stopped | **live** (check 3) |
| Two agents, one grant | The other agent isn't covered | Codex not covered by Claude Code's grant | synthetic (unit, CLI) |
| Legitimate `.env` read blocked; user recovers with one command | Understands; one command | The agent relayed the exact command; after it, the same read worked | **live** (checks 1a–1c). Whether a person understands it: **needs Sameeh** |
| Chrome extension disconnected | Popup and status say not checking | Status: "Not checking: …"; popup: "Not checking: Kai isn't connected" | status synthetic; popup **untested** (not loaded in Chrome) |
| Unknown action type | Not claimed | Status and COVERAGE list what isn't checked; unknown policy directives are reported, not applied | synthetic |
| Central acceptance test | Passes with a real Claude Code task | Security side partly live (above). Product acceptance (a person installs, works, recovers without disabling Kai) | **needs Sameeh** |

`kai demo --live` (live, 2026-10-29): Claude Code 2.1.312 Read of a fake `.env` stopped (session 939530bf); Codex 0.162.1 `cat` of it stopped (session 01a18738). A false-positive risk found during this run was fixed: the self-test is now an unlogged health probe and only the agent's own session counts.

## 3. Limits that stay (stated in README, status, doctor and CLI output)

- Hooks run with your permissions; a program the agent runs can get around them.
- Kai's rules and policy can be edited by any program with your permissions; integrity detects some outside changes, never all, and prevents none.
- `allow-fetch` governs only the agent's fetch tool; nothing else that reaches the host.
- The Chats matrix has no proven site yet.

## 4. Not done here (Part B / C)

The last commit before this spec (f9bd0d9) added app work that v2.1 moves to Part B and partly contradicts: **optional channels with fixed category switches** (B.4 says no fixed category switches) and GitHub/registries off by default in the network wall. Not changed in this pass ("No Part B work"); flagged for a decision.
