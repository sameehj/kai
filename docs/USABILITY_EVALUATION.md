<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# KAI — Usability / UX Evaluation

Written from real incidents in use. The goal is to name every usability problem
honestly, explain *why* it happens from the current architecture, and lay out
what has to change — including the agent-specific files, defaults, and endpoints
each LLM tool needs. Nothing here is implemented by writing this doc; it is the
evaluation that should drive the next milestones.

## TL;DR — the core failure mode

**Default-deny enforcement at the OS layer, with no in-the-moment, granular
approval, pushes the user to disable protection entirely to get work done.**

That is the worst outcome: the user ends with *no* protection *and* a bad
experience. It happened twice in one session:
1. The storage wall blocked Claude Code from reading its **own** settings →
   Claude wouldn't start.
2. The network wall blocked Claude Code from reaching **innermonkeylabs.com**
   (needed for legitimate MCP work on landing pages) → Claude reported "no
   internet."

In both cases there was **no notification, no "Allow this?" prompt, and no
granular override** — so the user turned **both walls off** to continue, was
never asked, and lost all protection. That is a UX failure, not a user error.

## Current architecture (so the problems are legible)

Two OS-level walls plus an advisory hook layer, all driven by a plaintext policy
file, with the menu bar + audit log as the only surfaces:

- **Storage wall** — an Endpoint Security system extension. Authorizes file
  opens/creates/renames/etc. for agent-attributed processes; denies protected
  paths. Enforcement is a kernel `AUTH` deny (`EPERM`). Modes: `off` (default) /
  `log` / `block`.
- **Network wall** — a `NEFilterDataProvider` content filter. Allows/drops new
  outbound flows for agent-attributed processes against an `egress_allow`
  allowlist. A denied flow is **dropped** at the socket layer. Modes: `log`
  (default, allow + record) / `block` / `off`.
- **Hook layer** — per-agent hooks (Claude/Cursor/Codex) that scan prompts/tool
  calls for secrets, injection, and exfil. Advisory: only sees what the agent
  routes through it.
- **Policy** — a shared file at `~/.kai/policy`; the extensions re-read it
  (network ~2 s; storage at start, soon live). No authenticated IPC; the menu
  bar shells the `kai` CLI and polls the audit log.
- **Approvals** — a Scoped-Approvals design exists for *storage* (grants, M0–M4,
  not live). There is **no approval mechanism for network egress at all**.

Key architectural fact: **enforcement is invisible to the agent.** The storage
deny is an `EPERM`; the network drop is a dead socket. The agent has no way to
know "Kai blocked this" vs "the file is missing" / "the network is down." Only
the menu bar / audit log carry that, and only if the user is looking.

## The problems (each: symptom → why → impact)

### P1. Blocks are opaque to the agent (and therefore to the user)
- **Symptom:** Claude said it had no internet; the storage block surfaced as a
  generic settings read error.
- **Why:** the network wall `.drop()`s the flow (looks like a dead network) and
  the storage wall returns `EPERM` (looks like a permission/missing-file error).
  Neither carries "blocked by Kai."
- **Impact:** the user can't tell a Kai block from a real failure, so they can't
  act on it — they just see a broken tool.

### P2. No in-the-moment notification or approval
- **Symptom:** nothing popped up offering to allow `innermonkeylabs.com` or the
  settings read; the user was "not asked."
- **Why:** Kai's notifications are one-way info banners gated on a setting, with
  no action buttons; there is no native approval dialog, and no network-approval
  flow at all. The storage Scoped-Approvals UI isn't live and doesn't cover
  network.
- **Impact:** the only recourse is to open the menu bar and toggle a whole wall.

### P3. All-or-nothing controls (no granular, temporary allow)
- **Symptom:** to do one MCP task against one domain, the user disabled the
  entire network wall *and* the storage wall.
- **Why:** the only easy control is wall on/off. Allowing one domain means
  editing `egress_allow` via CLI/policy (no UI button "Allow innermonkeylabs.com
  for 1 hour"); allowing one file has no UI either.
- **Impact:** protection is binary; routine work forces total disablement.

### P4. `egress = block` ships with an empty allowlist
- **Symptom:** turning the network wall to block blacks out *all* agent traffic,
  including the agent's own API (`api.anthropic.com`) and telemetry.
- **Why:** `policy/default.policy` has **zero `egress_allow` entries**; block
  mode denies everything not explicitly allowed (loopback aside).
- **Impact:** block mode is unusable without the user first hand-curating an
  allowlist they don't know they need. This is a defaults problem, not a bug.

### P5. "Show what was blocked" (`audit_context`) can be off, and blocks aren't
    all self-describing
- **Symptom:** `audit_context` was off, so the user couldn't see what was
  blocked; the storage block recorded only a rule (path-in-audit, v12, isn't
  live yet).
- **Why:** `audit_context off` keeps only the rule+reason (the excerpt it keeps
  when on is already secret-redacted, so "on" is safe). Network blocks *do*
  record the domain, but the storage path and the prompt/command excerpt don't
  without `audit_context on` + v12.
- **Impact:** poor visibility compounds P1 — the user is blind to causes.

### P6. The disable was silent and uninformed; no guided recovery
- **Symptom:** the user had to discover the walls were the cause and dig into
  settings to turn them off; `StorageWall` UI can even show "Off" while running.
- **Why:** no first-run onboarding, no "Kai is why this failed — here's what to
  do" surfacing, and a known UI state-refresh gap.
- **Impact:** frustration, and eventually blanket disablement.

### P7. Agent startup is blocked by protecting the agent's own config (fixed, v15)
- **Symptom:** Claude Code wouldn't start — blocked reading its own
  settings.json.
- **Why:** hook-config files were protected read+write; the wall didn't
  distinguish read from write (now fixed in v15: reads allowed, writes blocked).
  Still: **v15 is not live until reactivation.**

## Agent-specific files / defaults that MUST be handled

Each tool has config/state files it must read (and some write) to function, and
default network endpoints it must reach. Block mode has to account for all of
these or the tool breaks. (Typical paths/endpoints — verify per version; not
exhaustive.)

### Claude Code
- **Config/state (must read; some write):** `~/.claude/settings.json`,
  `~/.claude/settings.local.json`, project `.claude/settings.local.json`,
  `~/.claude.json` (session/state), `~/.claude/` subtree (projects, todos, shell
  snapshots, statsig), MCP config.
- **Secret-bearing:** `~/.claude/.credentials.json` / OAuth token in state — the
  agent reading its *own* auth is normal, but Kai's secret scanner could flag it.
- **Default endpoints:** `api.anthropic.com` (required), plus telemetry
  (`statsig.anthropic.com`, Sentry, and the observed
  `http-intake.logs.us5.datadoghq.com`).
- **Kai status:** hook-config reads now allowed (v15); the rest of `~/.claude`
  is not protected by default, so reads mostly work; **endpoints are NOT
  allow-listed**, so block mode kills Claude's API access.

### Cursor
- **Config/state:** `/Applications/Cursor.app/...`, `~/Library/Application
  Support/Cursor/`, `~/.cursor/` (`hooks.json`, extensions, `mcp.json`),
  workspace storage.
- **Default endpoints:** Cursor's API/backend (`*.cursor.sh` / `cursor.com`),
  the extension marketplace, and telemetry (observed:
  `mobile.events.data.microsoft.com`).
- **Kai status:** `.cursor/hooks.json` is control (read allowed v15, write
  blocked); endpoints not allow-listed.

### Codex CLI
- **Config/state:** `~/.codex/config.toml`, `~/.codex/hooks.json`,
  **`~/.codex/auth.json` (holds an OpenAI token!)**, sessions, logs; honors
  `CODEX_HOME`.
- **Default endpoints:** `api.openai.com` / ChatGPT backend.
- **Kai status:** `config.toml`/`hooks.json` are control (read allowed v15);
  `auth.json` is **not** in the protect list, so it's readable (the agent's own
  auth) — but note it is a real credential file; endpoints not allow-listed.

### MCP servers (the innermonkeylabs.com case)
- MCP servers are user-configured and connect to **arbitrary hosts the user
  chooses** (their own infra, GitHub, SaaS APIs). For landing-page work the agent
  legitimately needs `innermonkeylabs.com`.
- **Kai status:** there is **no concept of MCP endpoints** and **no network
  approval flow**; block mode drops them with no easy allow. This is the network
  analog of Scoped Approvals and does not exist yet.

**Implication:** block mode needs (a) a curated **default allowlist** of the
agents' own API/config endpoints, (b) **read-allow for agent config/state**
(partly done, v15), and (c) an **easy per-destination allow** for MCP/user infra
— ideally an in-context "Allow innermonkeylabs.com?" prompt, not a policy edit.

## macOS TCC prompts (Downloads / Desktop) — NOT Kai

On a new laptop, Cursor/Claude asking to access **Desktop, Downloads,
Documents** is **macOS's own TCC** (Transparency, Consent & Control), not Kai.
Kai's storage wall is a *separate* Endpoint Security layer. Two consequences:
1. Users will see **two different permission systems** (macOS TCC prompts + Kai
   blocks) and conflate them — a documentation/onboarding need.
2. They interact: an app must pass **both** TCC (user granted Desktop access)
   **and** Kai (path not protected / allowed) to touch a file. Kai should not
   add a *third* confusing prompt style; its approval UX should be clearly
   branded and distinct from the OS prompts.

## Recommendations (directions, prioritized — not yet built)

1. **Make blocks legible (highest impact for P1/P6).** When the wall denies an
   agent-attributed op, fire an **actionable notification**: "Kai blocked Claude
   Code → innermonkeylabs.com. [Allow once] [Allow 1h] [Always allow] [Deny]."
   Correlate the opaque agent failure to a cause the user can act on.
2. **Network approval flow (P2/P3/P4/MCP).** Extend Scoped Approvals to egress:
   a pending-request + human-approved, scoped, time-boxed `egress_allow` grant,
   with a one-click "allow this domain." This is the direct fix for the
   innermonkeylabs.com case.
3. **Curated default allowlists (P4).** Ship a known-good default `egress_allow`
   for the agents' own API/telemetry endpoints (opt-outable), and a known-good
   read-allow for agent config/state paths, so block mode is usable on day one.
4. **Granular, temporary allow in the UI (P3).** Per-domain and per-path "allow
   for N minutes" buttons, instead of wall on/off.
5. **`audit_context on` by default + ship v12 path-in-audit (P5).** Visibility
   by default; the excerpt is already redacted.
6. **First-run onboarding (P6).** Detect installed agents, pre-allow their
   endpoints/configs, explain TCC vs Kai, and start in `log` (observe) before
   `block`.
7. **Reconsider block-mode-as-default readiness.** Until 1–4 land, block mode
   should stay opt-in with a clear warning; `log` is the safe, usable default.
8. **Fix the StorageWall launch state refresh (P6).**

## What you can do *today* (while the above is unbuilt)

- Keep the **network wall in `log`** (its default) — it records agent egress
  without breaking it — rather than `block`.
- If you want block mode, first allow the endpoints you need, e.g.
  `kai policy add egress_allow api.anthropic.com`,
  `kai policy add egress_allow innermonkeylabs.com` (the network extension picks
  it up in ~2 s). This keeps protection on while unblocking the specific host —
  but the fact that this requires the CLI is exactly problem P3.
- For storage, prefer `log` (or `off`) until **v15** (read-allow for agent
  configs) is activated; v15 removes the startup breakage.

*This is an evaluation, not a change to enforcement. It should drive the next
milestones (network approvals, legible blocks, default allowlists, onboarding).*
