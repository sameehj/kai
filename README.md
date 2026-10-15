<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai

**A local security layer for AI coding agents.** Kai sits between your AI tools
and the outside world and stops secrets and company data from leaking to models
and LLM routers, and stops agents from touching your keys — with no change to
how you work.

> **Status: v0.1 (hooks).** This release protects **Claude Code** and **Cursor**
> through their hook systems, and gives you a policy engine, a secret/company-data
> scanner, and a tamper-evident audit log. It runs today on macOS and Linux with
> **no Apple approval required**. The decrypting proxy (covers Chrome, desktop
> apps and any provider) and the OS-level walls (Endpoint Security, Network
> Extension) are on the roadmap below.

```
          you ──prompt──▶  agent ──┬── reads a file?      Kai hook: deny if protected
                                   ├── runs a shell cmd?  Kai hook: deny upload / key access
                                   ├── calls an MCP tool? Kai hook: deny if it carries secrets
                                   └── a tool returns?    Kai hook: warn on prompt-injection text
```

## Why

AI agents run with your full user privileges. Research in 2025–2026 showed prompt
injection getting commands executed on real coding agents **up to 84% of the
time**, and adaptive attacks bypassing detection **>85%** of the time. One
poisoned README, web page or MCP tool can turn your agent into an attacker's
shell. Kai assumes **no model, router or agent is safe** and enforces your rules
locally.

## What it does in v0.1

- **Blocks reads of secret files** — `~/.ssh`, `~/.aws`, `.env`, `*.pem`, the
  keychain, and anything you add — for agent file reads *and* shell commands.
- **Blocks data exfiltration** — shell commands that look like uploads
  (`curl -d @file`, `curl … | sh`, `nc`, `scp`).
- **Cleans company data** — redact secrets, **replace** codenames
  (`Project Falcon` → `Project X`), or **block** on confidential markers, before
  text reaches a model or router.
- **Flags prompt injection** — warns the agent when a tool result contains text
  aimed at hijacking it.
- **Tamper-evident audit log** — every decision, hash-chained, no secrets stored.

## Install

One line (macOS and Linux). Installs the `kai` command, plus the menu-bar app
on macOS once a release is published, and writes a default policy. It does not
touch your agents' settings:

```sh
curl -fsSL https://raw.githubusercontent.com/sameehj/kai/master/install.sh | sh
```

Add `KAI_HOOKS=all` before `sh` to also turn Kai on for Claude Code and Cursor.
The script checks release downloads against `SHA256SUMS` and falls back to
building from source (needs `cc` and `make`).

Homebrew:

```sh
brew tap sameehj/kai https://github.com/sameehj/kai
brew install --HEAD kai     # plain `brew install kai` after the first release
```

From source:

```sh
git clone https://github.com/sameehj/kai
cd kai
make
sudo make install          # puts `kai` in /usr/local/bin
make install-app           # macOS: menu-bar app -> /Applications/Kai.app
```

Then:

```sh
kai init                   # write ~/.kai/policy (edit it for your company)
kai install claude         # add Kai hooks to ~/.claude/settings.json
kai install cursor         # add Kai hooks to ~/.cursor/hooks.json
kai doctor                 # check everything is wired up
```

Uninstall is clean and keeps your own hooks: `kai uninstall all`.

## Menu-bar app (macOS)

`Kai.app` puts a shield in the menu bar:

- **Status at a glance:** protecting, partly protecting, off, or a problem
  such as a policy error.
- **One switch per agent** to turn Kai on or off for Claude Code and Cursor.
- **Notifications** when Kai blocks something, and a list of recent activity.
- **Settings** for the protection switches, protected files, and company terms
  and codenames. Changes go through `kai policy`, so the app and the terminal
  always agree.

The app needs no special permissions, only notifications.

## AI gateway

`kai gateway` runs a local server that cleans what agents send to model APIs:
secrets are redacted, codenames replaced, and requests with confidential
markers blocked, before anything leaves your machine. Replies stream back
unchanged. Point an agent at it:

```sh
kai gateway &                                             # 127.0.0.1:8787
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude           # Claude Code
OPENAI_BASE_URL=http://127.0.0.1:8787/openai/v1 codex     # Codex / OpenAI SDKs
```

It listens on loopback only and forwards only to fixed provider URLs, using
the agent's own API key.

## Network and storage walls (in progress)

System-wide walls for macOS, built as Apple system extensions so you start
your agents normally (no wrapper). See [`docs/WALLS.md`](docs/WALLS.md).

- **Done in the engine:** agent identification (`kai agent-of <pid>`), the
  egress allowlist (`egress log|block`, `egress_allow`), and a TLS server-name
  parser.
- **Next:** the Network Extension that enforces them. It needs a paid Apple
  Developer account.
- **After that:** the Endpoint Security file wall, once Apple grants the
  entitlement.

## Policy

One readable file at `~/.kai/policy`. Missing file = safe defaults.

```text
protect ~/.ssh
protect .env
allow   .env.example

secrets redact                        # redact | block | warn | off

term  replace:"Project X"  Project Falcon
term  block                CONFIDENTIAL
rule  internal_host redact [a-z0-9-]+\.corp\.example\.com
```

See [`policy/default.policy`](policy/default.policy) for the full set.

## Commands

| Command | What it does |
|---|---|
| `kai install [claude\|cursor\|all]` | Wire Kai into an agent (keeps a `.kai-bak`) |
| `kai uninstall [claude\|cursor\|all]` | Remove only Kai's entries |
| `kai scan [file…]` | Report secrets and company terms (stdin if no files) |
| `kai redact` | Clean text from stdin to stdout |
| `kai doctor` | Check policy and installs |
| `kai status --json` | Status for scripts and the menu-bar app |
| `kai policy show [--json]` | Print the policy |
| `kai policy set <switch> <value>` | Change a switch, e.g. `on_upload ask` |
| `kai policy add\|remove protect\|allow <path>` | Edit protected paths |
| `kai policy add term <action> <text>` | Add a company term (`block`, `redact`, `warn`, `replace:"X"`) |
| `kai policy add egress_allow <host>` | Let agents reach a host (and its subdomains) |
| `kai gateway [--port N]` | Run the local AI gateway |
| `kai agent-of <pid>` | Show whether a process is an agent or runs under one |
| `kai log [tail\|verify]` | View or verify the audit log |

`kai scan` doubles as a git pre-commit secret check (exit code 1 on findings).

Policy edits are checked before they're written: a change that would break the
policy is rejected. Agents can't change Kai's settings: a shell command from an
agent that runs `kai install`, `kai uninstall`, `kai init` or
`kai policy set|add|remove` is always blocked.

## Roadmap

- **v0.1 (now):** hooks for Claude Code and Cursor, policy engine, scanner, audit log.
- **v0.2:** local decrypting proxy for AI domains (Chrome, Cursor, desktop apps,
  OpenRouter) — reads and cleans prompts with no hooks; credential proxy.
- **v0.3:** macOS Endpoint Security + Network Extension walls (file and network
  enforcement for *every* app, even through scripts); small local judge model.
- **Later:** Linux (eBPF/Landlock), Windows (user-mode first), Kai Teams
  (central policy, fleet audit, SSO).

## How it's built

A small C11 core (`libkai`) with a stable C API ([`include/kai.h`](include/kai.h)),
plus thin command/hook/installer code. Dependencies: POSIX regex, libcurl for
the gateway (built into macOS; `libcurl4-openssl-dev` on Debian/Ubuntu), and a
vendored MIT copy of [cJSON](third_party/cjson/). The same code builds on macOS
and Linux. See [`docs/DESIGN.md`](docs/DESIGN.md) and
[`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).

## Contributing

We welcome contributions — new detectors, new agent integrations, attack-suite
cases. Contributors sign a short [CLA](CLA.md) so the project can keep offering
commercial licenses alongside the open-source one. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

Kai is dual-licensed:

- **Open source:** [GNU GPL v3](LICENSE). Use, study, modify, and share.
- **Commercial:** to embed Kai's engine in a closed-source product, buy a
  commercial license. See [`COMMERCIAL.md`](COMMERCIAL.md).

"Kai" and the Kai logo are trademarks; see [`TRADEMARKS.md`](TRADEMARKS.md).
To report a vulnerability, see [`SECURITY.md`](SECURITY.md).
