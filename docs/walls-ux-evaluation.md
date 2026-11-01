<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai Walls — UX Evaluation & Problem Inventory

> **Build order superseded by [`docs/security/RECONCILED-PLAN.md`](security/RECONCILED-PLAN.md)** (Security Plan v1.0, frozen Oct 31, 2026). This document keeps its specs and tests; where it conflicts with the spec, the spec wins.

Oct 23, 2026 · @Sameeh Jubran

Kai can be technically correct and operationally unsuccessful: on October 22 it
blocked an unauthorized destination, the user could not see why or approve the
legitimate task, and switched both walls off. The fix is not blocking less. It is
that every denial is explainable, and every legitimate exception can be granted
narrowly without weakening unrelated protection. Not every denial deserves an
approval button.

This revision folds in the October 23 critical review: 23 problems (the original
17 plus 6 foundational security problems), corrected assumptions, milestones
M0–M3 with acceptance criteria, and a release test matrix. The step-by-step build
plan is in `docs/walls-action-plan.md`.

**Success measure:** a user keeps both walls on through a normal working day,
using Git, MCP servers, dev tools and several agents, without ever opening a
terminal to edit policy.

## What happened on October 22

On October 22 at 17:03:54 UTC, Claude Code tried to reach innermonkeylabs.com (a
Cloudflare IPv6 address, port 443) to do MCP work on landing pages. The network
wall dropped the connection because the host was not on the egress allowlist.
Event id 5d79517850.

What the user experienced, in order:

1. Claude Code reported that it had no internet. It did have internet; one
   destination was being refused by Kai. The agent cannot tell a dropped flow
   from an outage, so it guessed wrong.
2. No notification appeared. The "show what was blocked" setting was off, so the
   block was only in the log.
3. Claude Code also could not reach its own settings while the storage wall was
   on.
4. Nothing offered a way through: no prompt, no "allow this host", no "allow for
   this session".
5. The user turned off both the storage wall and the network wall to finish the
   work. The machine then had no protection at all.

Why it blocked: per the policy check run in the earlier session, the shipped
defaults are egress = log, storage = off, and an empty egress allowlist. Default
Kai blocks nothing. Once egress is switched to block, every agent destination
that is not explicitly listed is dropped, including the model API itself unless
it is special-cased. Turning the wall on and turning on a near-total block are
currently the same action.

The block record itself is also misleading. It reads "Rule: innermonkeylabs.com",
which looks like a rule matched that host. In fact no rule matched; the
destination was simply absent from an empty list.

## Current architecture

Kai is one signed macOS app with two system extensions and a shared C policy
engine. Enforcement is system-wide and wrapper-free: you launch agents normally,
and Kai decides per process and per action.

*[diagram: current Kai architecture · 4 checkpoints, 1 policy engine]*

Kai has demonstrated real enforcement, but has not yet proven complete coverage.
The feedback half is missing entirely: every decision lands in the audit log, and
the menu-bar app, silent by default, is the only path from a decision to a human.

- **Process tagging.** On exec, the storage extension tags known agents by
  code-signing identity or path. Children inherit the tag. Known gap: processes
  detached through launchd can lose their attribution.
- **Hooks (L1).** Claude Code and Cursor hooks clean content inside the agent.
  Best effort only: a script the agent runs never passes through them.
- **Storage wall (Endpoint Security).** On each file open by a tagged process,
  libkai decides; protected means deny. Every AUTH event has a kernel deadline, so
  the handler can never wait for a human. It cannot see Keychain items: those are
  reached through the macOS security service, not file opens.
- **Egress filter (Network Extension content filter).** Sees each outbound flow
  with its process. Tagged flows reach only allowlisted hosts. Sees hostnames and
  IPs, never content. Verdicts are allow, drop, pause and remediate; a chosen TCP
  reset is not among them.
- **AI proxy (Network Extension transparent proxy).** Redirects model-API traffic
  from tagged processes to the local gateway, which redacts, replaces or blocks.
  (NOTE: not built yet — see the Phase 0 audit; only a manual opt-in `kai gateway`
  exists today.)
- **libkai and policy.** One engine and one policy file drive all four. Earlier
  milestones (M0–M4) added a permission engine, CLI, grant store and UI wiring
  with code-level tests; none is yet proven against live extensions.
- **Menu-bar app.** Owns install, on/off, settings and notifications. Today it
  offers only global on/off per wall.

**Unverified composition, treated as a risk until tested:** if the egress filter
allows a model-API host, nothing yet proves that traffic went through the AI proxy
rather than straight to the provider. That would be a gateway bypass, not a UX
issue.

## Problem inventory

Twenty-three problems in six groups; 13 are Critical. Groups A–E are what the user
feels. Group F is foundational: fixing the interface without it would make Kai
feel safe while granting overly broad access underneath. The Milestone column maps
each problem to the plan.

| # | Problem | Solution | Severity | Milestone |
|---|---|---|---|---|
| **A. Visibility** | | | | |
| 1 | Blocks are silent; "show what was blocked" is off | Notify on meaningful denials with agent, target, reason; group repeats | Critical | M0 |
| 2 | Agent blames the wrong cause ("no internet") | Read-only, sanitized denial record the agent can query: reason + event id; no grant power | Critical | M0 record, M3 agent integration |
| 3 | Record says "Rule: \<host>" when no rule matched | "Destination not on allowlist; no rule matched" | Medium | M0 |
| 4 | No recent-activity view | Activity screen filterable by agent, session, project, allowed, denied, pending | High | M0 |
| **B. Defaults** | | | | |
| 5 | Block mode with an empty allowlist breaks everything | Core trusted channels per agent pre-allowed; optional channels by choice; unknown blocked or asked | Critical | M2 |
| 6 | Kai does not know each agent's needs | Versioned, tested per-agent resource profiles: hosts, operational files, credential boundaries | Critical | M2 |
| 7 | Storage wall can block an agent's own settings | Allow the specific operational files needed; never a blanket directory exception | Critical | M2 |
| 8 | Breakage discovered only after enforcing | Observe mode with suggested rules; enforcement an explicit step; say clearly that observe mode protects nothing | High | M3 |
| **C. Permissions** | | | | |
| 9 | No way to approve one legitimate action | Build on the existing grant engine: task, session or project grants, only where identity is reliable | Critical | M1 |
| 10 | Grants not scoped to project | Bind grant to verified session, project, resource and operation; never a working-directory name alone | High | M1 |
| 11 | Walls switched off stay off | Pause with auto-resume and warning; full disable stays in Settings | High | M1 |
| 12 | Permissions need policy-file editing | Visual permission manager: who, what, how long, why, revoke | Medium | M3 |
| **D. Agent behaviour** | | | | |
| 13 | MCP integrations blocked | Discover MCP endpoints and show them for review; user grants in Kai policy | High | M2 |
| 14 | Agents retry blocked operations | Explainable failure first; investigate faster failure where the platform allows; group repeats | Medium | M3 |
| 15 | Attribution lost for detached processes | Code-signing identity, ancestry and durable ids (pid + pidversion, audit token); test launchd-detached children explicitly | Critical | M1 |
| **E. Onboarding** | | | | |
| 16 | macOS folder dialogs confused with Kai | Explain macOS app-level permissions versus Kai's per-agent rules, and what each approval changes | High | M3 |
| 17 | No first-run guidance | Setup wizard: explain walls, verify macOS approvals, detect agents, review profiles, choose mode | Medium | M3 |
| **F. Foundations** | | | | |
| 18 | Kai cannot prove its protection state | Measured health: extension active, policy version loaded, grants observed by enforcement, attribution coverage, gateway routing | Critical | M0 |
| 19 | A grant could apply to the wrong session | Session identity anchored on the agent root's audit token; unattributable actions never reuse a session grant | Critical | M1 |
| 20 | Allowed domains can still carry exfiltration | Separate destination authorization from content protection; say which traffic is only destination-checked | Critical | M2 |
| 21 | Agents can manufacture permission requests via config | Agent config is untrusted: it can request, never grant | Critical | M2 |
| 22 | Waiting for consent inside an ES callback breaks deadlines | Deny immediately, request asynchronously, grant future access, agent retries | Critical | M1 |
| 23 | Approvals could be forged | Separate read-only and policy-changing interfaces; authenticate the approver; protect grant storage from agents; audit every change | Critical | M1 |

Not every problem needs its own feature. Grants (9, 10, 19, 22, 23) are one
design; visibility (1, 3, 4, 18) is one surface; profiles (5, 6, 7, 13, 21) are
one data model.

## Agent profiles: what each agent needs, and what it must not get

Each agent needs a versioned profile of narrowly defined resources, not a generic
allowlist and not a blanket directory exception. A trusted destination never means
trusted content: a domain allowlist is an egress boundary, not data-loss
prevention.

**Network: three channel classes**

- **Core trusted channels.** Model, sign-in and essential service hosts for a
  verified agent. Pre-allowed, and model traffic must still route through the AI
  proxy.
- **Optional service channels.** Updates, package registries, plugins, MCP
  servers. Off until the user enables them; package registries carry supply-chain
  risk as well as exfiltration risk.
- **Unknown destinations.** Blocked, or shown for a scoped grant, per policy.

| Agent | Core trusted channels | Optional service channels |
|---|---|---|
| Claude Code | api.anthropic.com, claude.ai, claude.com, platform.claude.com | mcp-proxy.anthropic.com (claude.ai connectors), registry.npmjs.org, github.com (plugins), downloads.claude.ai (updates), bridge.claudeusercontent.com (Chrome), code.claude.com (docs); Datadog telemetry hosts can be disabled instead |
| Cursor | api2.cursor.sh, api5.cursor.sh, authenticate.cursor.sh, authenticator.cursor.sh (prefer named hosts over *.cursor.sh) | *.cursor-cdn.com, marketplace.cursorapi.com, *.cursorvm.com |
| Codex CLI | OpenAI API and ChatGPT sign-in hosts (to verify) | MCP servers, registries |
| Gemini CLI | Google AI API and Google OAuth hosts (to verify) | MCP servers, registries |

Broad wildcards widen the exfiltration surface; profiles should list named hosts
wherever the vendor documents them.

**MCP configuration is untrusted input.** A prompt injection can make an agent add
a server pointing at an attacker. So Kai may discover endpoints in `.mcp.json` and
similar files, record where and when each appeared, and show them for review. The
grant lives only in Kai-controlled policy. A declared URL also does not describe
everything a server does: it may run local commands, fetch packages or contact
other hosts. **Invariant: agent-controlled configuration can request permissions,
never grant them.**

**Storage: classify resources, not directories**

| Resource class | Example (Claude Code) | Default policy |
|---|---|---|
| Settings needed to start | ~/.claude/settings.json | Allow the necessary reads |
| Project instruction files | CLAUDE.md, AGENTS.md, .claude/settings.json | Allow, subject to content controls |
| Session history | ~/.claude/projects/ transcripts | Restrict cross-session access where feasible |
| Authentication tokens | Keychain entry; token files for agents that use them (e.g. ~/.codex/auth.json) | Protect; allow only narrowly necessary operations |
| Private keys, external credentials | ~/.ssh, ~/.aws, cloud keys | Deny; no casual one-click exception |
| Kai policy and grant store | ~/.kai/ | Hard deny for every agent, read and write |
| Plugin executables | ~/.claude/plugins/ | Allow loading; monitor modification |
| Project env files | ./.env | Ask or deny per project policy |

Two limits to state honestly. First, Keychain-held secrets are not files, so the
ES wall cannot guard them; macOS's per-app Keychain access rules do. Second, if an
agent legitimately holds a credential, Kai cannot guarantee the model or
subprocesses never see it. The long-term answer is a credential broker that
performs the operation without handing over the raw secret.

Paths for Codex and Gemini, and every profile entry, must be verified against
installed versions and tested under enforcement before shipping.

## macOS folder-permission prompts on first launch

The Desktop, Downloads and Documents prompts on the new laptop came from macOS,
not from Kai, but the user experiences them as one stack of security dialogs with
no way to tell them apart. Kai is the only security product on the machine, so it
owns explaining all of them.

macOS privacy controls (TCC) gate a few folders per app: Desktop, Documents,
Downloads, iCloud Drive, network and removable volumes. The first time an app
touches one, macOS asks once and remembers the answer for that app.

**Why agents trigger them on first launch**

- An agent started from the home folder, or asked a broad question, lists or
  searches its surroundings and hits a protected folder.
- Cursor indexes and watches its workspace; a workspace at or above the home
  folder pulls in Desktop and Downloads.
- For a terminal agent such as Claude Code, macOS attributes the request to the
  terminal app (Terminal, iTerm, Ghostty), not to `claude`. Clicking Allow grants
  that whole terminal, and everything ever run in it, permanently.

**The full stack a new user sees**

| Dialog | Who asks | Trigger | What Kai should say about it |
|---|---|---|---|
| Allow system extension | macOS, for Kai | Kai activation | Required once; the walls do not run without it |
| Filter network content | macOS, for Kai | Network wall activation | Required once; Kai checks destinations, and inspects content only for model traffic it proxies |
| Full Disk Access | macOS, for Kai's storage extension | Storage wall activation | Required so Kai can see file opens and deny the dangerous ones |
| Notifications | macOS, for Kai | First block notice | Optional; without it, denials still appear in Kai's Activity view |
| "Terminal would like to access Downloads" | macOS, for the terminal hosting the agent | Agent touches Downloads | Grants that terminal and everything run in it access to the folder, permanently |
| "Cursor would like to access Desktop" | macOS, for Cursor | Indexing or a search reaches Desktop | Same, for Cursor |

**How the two layers relate.** macOS grants access per application and per folder.
Kai applies additional, per-path restrictions to recognized agent processes.
Allowing Downloads does expand what that terminal, and anything attributed to it,
can reach under macOS rules. Kai's wall still restricts tagged agent operations,
but only where its attribution and enforcement are working. Kai cannot answer or
suppress a macOS prompt.

For fleets, an MDM privacy profile can pre-decide some of these folder permissions
per app, alongside the existing extension pre-approval. Which ones can be
pre-allowed should be confirmed per service before promising zero prompts.

## Approval design

One user experience, two enforcement paths. Storage decisions must be made inside
a kernel deadline, so Kai denies at once and grants future access; it never holds
a syscall open for a human. Network flows have pause and resume verdicts, but the
same deny-then-retry model keeps both walls predictable. The UI must distinguish
"permission granted" from "operation retried successfully".

*[diagram: target block-to-decision flow · 4 choices]*

**What the notice shows:** agent and session, project, exact resource (host:port or
path), operation, reason ("destination not authorized for this session"), and the
agent's stated purpose labelled "reported by agent, not verified". Repeats from one
session, resource and reason collapse into one notice with a count.

There is no "Always allow" in the notice. Persistent, broad exceptions are made
deliberately in Settings. Network "this task" covers the destination for a short
window, because one MCP task opens several connections.

**Risk tiers: not every denial is overridable**

| Request | Behaviour |
|---|---|
| Read a normal project file | Allow |
| Contact a newly configured MCP host | Ask, with scoped grant |
| Read a project env file | Ask or deny per project policy |
| Read ~/.ssh private keys, cloud credentials | Deny; no one-click exception |
| Modify Kai's policy or grant store | Hard deny for agents, always |
| Delete a large project directory | High-risk confirmation even with project access |

**Authenticated approval.** An approval is only trustworthy if an agent cannot
produce one. The read-only interface (denial records, status) and the
policy-changing interface (grants) are separate. Grant creation requires an
authenticated user action in Kai's own UI, grant storage is unwritable by agents,
and every change is audited.

## Protection health

A toggle saying "Storage ON" proves nothing. Kai should report measured states,
each distinct from its configured counterpart:

- Extension installed versus active and responding.
- Policy configured versus the version each extension has loaded.
- Grant written versus grant observed by enforcement, and the revocation latency.
- Agent recognized versus its process tree fully attributed.
- Gateway configured versus model traffic actually passing through it.

## Milestones

> *Superseded (order of work): see `docs/security/RECONCILED-PLAN.md`. Kept as a record.*


Audit what M0–M4 already built before writing anything new; close the gap between
tested grant logic and live macOS enforcement rather than rebuilding it.

| Milestone | Scope | Problems | Acceptance |
|---|---|---|---|
| **M0: Make failure visible** | Audit wording, Activity view, grouped notifications with fallback, measured health, sanitized denial record | 1, 2, 3, 4, 18 | User identifies any blocked action without logs or disabling a wall |
| **M1: Make legitimate access possible** | Verify grant engine against live extensions; session identity; authenticated approvals; deny-then-retry; expiry and revocation reach both walls; safe pause | 9, 10, 11, 15, 19, 22, 23 | The October 22 MCP request is approved for one session only, both walls stay on, Claude completes the task |
| **M2: Make secure defaults usable** | Versioned agent profiles, resource classes, MCP review, channel classes, gateway-routing guarantee | 5, 6, 7, 13, 20, 21 | Claude Code, Codex and Cursor complete baseline workflows under enforcement with no broad exceptions |
| **M3: Make it pleasant** | Observe-first onboarding, wizard, permission manager, agent-readable diagnostics, faster failure where possible | 2, 8, 12, 14, 16, 17 | A new user understands their protection state and finishes normal tasks without opening Settings repeatedly |

MDM and Teams features wait until Community enforcement is dependable.

## Release tests

Each must pass on the real, signed system extensions, not simulated or unit-level
checks.

| Test | Required outcome |
|---|---|
| October 22 replay: Claude MCP website update | Narrow approval works; neither wall is turned off |
| Two concurrent Claude sessions | Grant to session A does not authorize session B |
| Detached child via launchd | No access from lost attribution; falls back to deny |
| Agent edits its MCP config | No automatic network authorization |
| Agent reads its own settings | Works without exposing session history or tokens |
| Agent requests ~/.ssh private key | Denied |
| Grant expires while agent runs | Later operations denied within a defined bound |
| Agent floods 1,000 denials | UI responsive; one grouped notice |
| Menu-bar app crashes | Enforcement continues per fail-safe policy |
| Agent spoofs session metadata | Cannot obtain another session's grant |
| Agent connects to model API directly, bypassing proxy | Blocked or forced through the gateway |
| Policy update during enforcement | No temporary access window |
| Agent attempts to write a grant or call the grant interface | Refused and audited |

## Principles

1. Users never have to disable all protection to finish ordinary work.
2. An agent can request permission, never grant it.
3. Every permission is as narrow and temporary as practical.
4. Users see what was blocked without drowning in prompts.
5. Kai never claims a guarantee its live enforcement cannot demonstrate.

## Open questions

- [x] Which exact path did the storage wall deny when Claude Code lost its settings? The Phase 0 audit records `~/.claude/settings.json` and `~/Research/.claude/settings.local.json`.
- [ ] Was egress switched to block by the user, or did a build ship with block on?
- [ ] What does a content-filter drop look like to the calling process on current macOS: immediate error or timeout? Measure before promising fast failure.
- [ ] Does traffic to an allowlisted model host always pass through the AI proxy? Prove with a live test.
- [ ] How far does root-audit-token session identity get us, and what is the fallback for launchd-detached processes?
- [ ] Network "this task" window: how long, and per host or per host:port?
- [ ] Notification grouping thresholds and rate cap.
- [ ] Who maintains agent profiles, and how fast do updates ship after an agent adds a host?
- [ ] Confirm Codex CLI and Gemini CLI hosts and credential paths.
- [ ] Codex `.codex/config.toml` writes: keep the present hard deny, or allow writes as untrusted configuration changes that Kai logs and checks for new MCP endpoints? Decide for the Codex profile after a live read-only versus write-open trace. Approval grants must not silently settle this policy question.

## Sources

- Claude Code: Enterprise network configuration (required hosts, telemetry, fast-rejection advice) — https://code.claude.com/docs/en/network-config
- Cursor: Network configuration (required domains) — https://cursor.com/docs/enterprise/network-configuration
- Cursor: Network troubleshooting (domain wildcards) — https://cursor.com/help/troubleshooting/network
- Internal: docs/walls-macos-design.md and docs/open-source-and-apple.md (referenced; not yet present in repo as of this writing).
