<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->

<div align="center">
  <img src="assets/kai-logo.png" alt="Kai shield logo" width="132" />

  # Kai

  ### Protect what matters. Build with AI.

  **Your agents can move fast. Your secrets shouldn't move with them.**

  Local protection for AI coding agents: safeguard sensitive files, catch secrets before they're shared, and control risky actions.

  [Get started](#-get-started) · [How it works](#-how-kai-works) · [Security boundaries](#-what-kai-doesnt-promise) · [Roadmap](#-roadmap)

  **macOS + Linux** · **Claude Code + Cursor hooks** · **Codex hooks (preview)** · **Open source**
</div>

---

## 🛡️ Why Kai?

AI coding agents can read files, execute commands, and call external services using your privileges. One malicious instruction or unintended action could expose credentials, confidential code, or company information.

Kai puts local rules around supported agent actions so you can use AI tools with more visibility and control — without changing your development workflow.

**You decide what matters. Kai helps protect it.**

## ✨ What Kai can do today

| Layer | What it does | Status |
| --- | --- | --- |
| **Agent hooks** | Deny protected file reads and suspicious commands in Claude Code and Cursor; examine supported tool and prompt events | ✅ Working and tested |
| **Codex hooks** | Same checks for OpenAI Codex CLI (shell commands, `apply_patch` edits, MCP arguments, prompts) | 🧪 Implemented, not yet tested with real Codex |
| **Policy + scanner** | Redact detected credentials, replace company terms, or block confidential markers | ✅ Working and tested |
| **Audit log** | Record decisions in a hash-chained log without storing detected secret values | ✅ Working and tested |
| **macOS menu-bar app** | Show status, recent activity, protection switches, and policy controls | ✅ Running in development |
| **Local AI gateway** | Inspect and transform requests explicitly routed through it to supported model APIs | 🧪 Tested with a fake upstream; live-agent testing pending |
| **Network wall** | Use a signed macOS Network Extension to log or restrict agent connections by destination | ✅ Log mode verified on macOS 14 · 🧪 Block mode not yet tested |
| **Storage wall** | Use macOS Endpoint Security for stronger agent file restrictions | 🗓️ Planned; Apple entitlement required |

**Important:** Hooks only see actions exposed by supported agent hook integrations. They are not OS-level sandboxing. The gateway protects only traffic routed through it. See [security boundaries](#-what-kai-doesnt-promise).

## 🚀 Get started

### 1. Install Kai

**Build from source** (works now; requires a C compiler and `make`):

```sh
git clone https://github.com/sameehj/kai.git
cd kai
make
sudo make install
```

**Installer script** (review before executing):

```sh
curl -fsSLo kai-install.sh https://raw.githubusercontent.com/sameehj/kai/master/install.sh
less kai-install.sh
sh kai-install.sh
```

The installer is designed to verify release files against `SHA256SUMS` when available and fall back to a source build. A checksum hosted beside its artifact is not an independent authenticity guarantee. Public binary releases and notarized macOS distribution are not confirmed yet.

**Homebrew (source build):**

```sh
brew tap sameehj/kai https://github.com/sameehj/kai
brew install --HEAD kai
```

### 2. Turn on agent protection

```sh
kai init
kai install claude
kai install cursor
kai install codex      # preview; Codex asks you to trust new hooks once
kai doctor
```

These commands write the default policy, integrate Kai into the agents' hook settings, and inspect the resulting setup. Kai preserves prior settings via backups when installing its entries. You can enable just one agent if you prefer.

### 3. See what Kai catches

```sh
kai scan .env                 # inspect a file for secrets and company terms
kai status --json            # inspect local status
kai log tail                 # inspect recent decisions
kai log verify               # verify the audit hash chain
```

Edit `~/.kai/policy` to define which paths, secrets, and company terms are sensitive to you.

## ⚙️ How Kai works

```text
You → AI coding agent
          │
          ├─ File read       → Kai hook → allow / deny
          ├─ Shell command   → Kai hook → allow / deny
          ├─ MCP/tool event  → Kai hook → inspect / redact / block
          └─ Tool response   → Kai hook → flag suspicious instructions

Optional: supported agent → Kai local gateway → model API
                        (only if explicitly configured)

macOS: agent process (and its children) → Network Extension
          → host on allowlist? allow : log (or drop in Block mode)
```

### Protect sensitive files

Kai can deny supported agent operations that target files such as `~/.ssh`, `~/.aws`, `.env`, or `*.pem`, along with your own protected paths. It can also detect certain risky shell commands, including upload patterns such as `curl -d @file`, `scp`, and `nc`.

These are **hook-level checks**, not guaranteed prevention against arbitrary shell scripts, alternate encodings, or every way to access files.

### Keep company context in your control

Kai's local scanner supports four actions: **redact**, **replace**, **block**, and **warn**. For example, your own policy can replace an internal codename before text is sent through an inspected path.

```text
protect ~/.ssh
protect .env
allow   .env.example

secrets redact
term replace:"Project X" Project Falcon
term block CONFIDENTIAL
rule internal_host redact [a-z0-9-]+\.corp\.example\.com
```

See [`policy/default.policy`](policy/default.policy) for the complete policy grammar.

### Review what happened

Kai records local decisions in a hash-chained audit log. This helps detect some unauthorized changes, but it is **not tamper-proof** against an attacker who controls the log and its verification state.

## 🌐 Optional AI gateway

The local gateway can inspect outgoing model API requests from clients configured to use it. It listens on loopback and forwards to configured, fixed provider destinations.

```sh
kai gateway &
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude
OPENAI_BASE_URL=http://127.0.0.1:8787/openai/v1 codex
```

**Current maturity:** Tested against a fake upstream, not yet verified end-to-end with real Claude Code. Cursor's built-in model requests are not redirected by this configuration; its supported hooks remain the current integration path.

## 🍎 macOS app and system protection

`Kai.app` is a menu-bar interface for local status, agent switches, notifications, recent events, and policy changes. A development build is running; distribution to other Macs requires the appropriate signing and notarization steps.

The **Network wall** is a signed Network Extension that checks connections made by agent processes (Claude Code, Cursor, Codex and anything they start) against an egress allowlist. Other apps are left alone.

**Verified so far (macOS 14, Log mode):** a request from Claude Code to `example.com` was recorded in the audit log; a request to allow-listed `github.com` was not; requests from non-agent apps were not inspected. It also surfaced Claude Code's own telemetry connection, which is the kind of visibility Log mode is for.

- **Destinations are matched by hostname** for web traffic on ports 80 and 443 (TLS server name or HTTP `Host`). Other traffic, such as SSH, is logged but **not blocked**.
- **Block mode** (`egress block`) is implemented but **not yet tested**. Do not rely on it as egress containment yet.
- **Turning it on** takes one approval in System Settings → Privacy & Security, plus the "filter network content" prompt.

```sh
make try-app KAI_TEAM=<your Apple team ID>   # build signed, install to /Applications, open
systemextensionsctl list                     # expect: io.github.sameehj.kai.network … [activated enabled]
kai log tail                                 # network entries have "source":"network"
```

Building the extension needs a paid Apple Developer account. A development build only runs on Macs registered to that account.

The planned **Storage wall** uses macOS Endpoint Security and requires an Apple-granted entitlement. Details: [`docs/WALLS.md`](docs/WALLS.md).

## 🔍 What Kai doesn't promise

Kai is a **layer of defense**, not a guarantee against data leakage or malicious agent behavior.

- Agent hooks can be bypassed by activities that do not pass through them; they do not confine arbitrary agent-spawned processes.
- The gateway cannot inspect requests that never route through it, nor traffic encrypted end-to-end through an unknown route.
- Secret and prompt-injection detectors can miss new patterns or produce false positives. Prompt-injection checks currently **warn** on detected suspicious tool text; they do not prove that a model will ignore it.
- The network wall has been verified in Log mode only; Block mode has not been tested. Non-web traffic is not blocked, and an allowlist cannot stop data sent *to* an allowed host. A process that detaches from its agent (re-parented to `launchd`) is no longer recognized as part of the agent.
- Host-local log hash chaining does not defend against a fully compromised host.

Read [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md) before using Kai for sensitive or regulated workflows.

## 🧰 CLI reference

| Command | Purpose |
| --- | --- |
| `kai install [claude\|cursor\|codex\|all]` | Add supported agent hooks (`all` adds Codex only if `~/.codex` exists) |
| `kai uninstall [claude\|cursor\|codex\|all]` | Remove Kai's hook entries while preserving other hooks |
| `kai scan [file…]` | Find configured secret/company patterns; stdin if no files |
| `kai redact` | Apply text-cleaning policy from stdin to stdout |
| `kai doctor` | Check local configuration and integrations |
| `kai status --json` | Report status for scripts and app |
| `kai policy show [--json]` | Inspect policy |
| `kai policy set <switch> <value>` | Change a protection switch |
| `kai policy add\|remove protect\|allow <path>` | Edit protected or allowed paths |
| `kai policy add term <action> <text>` | Add a company term rule |
| `kai policy add egress_allow <host>` | Add an allowed destination and subdomains |
| `kai gateway [--port N]` | Start the loopback AI gateway |
| `kai agent-of <pid>` | Identify a recognized agent/descendant process |
| `kai log [tail\|verify]` | Inspect or verify audit records |

`kai scan` can also be used as a git pre-commit check (non-zero exit on findings). Kai's hook policy blocks recognized agent attempts to run selected Kai administration commands; this is not protection against every indirect filesystem modification.

## 🗺️ Roadmap

- **Now — v0.1:** Claude Code/Cursor hooks, local policy and scanner, hash-chained audit, CLI; development menu-bar app; macOS network wall (Log mode verified).
- **Validation next:** Test network-wall Block mode, add DNS correlation so non-web traffic can be attributed to a host, and exercise the gateway with real agents.
- **Then:** Build and validate an optional decrypting proxy and credential handling where technically and legally appropriate; pursue Endpoint Security approval and stronger file restrictions.
- **Later:** Linux OS-level enforcement (eBPF/Landlock), Windows support, and optional team policy/fleet management.

Roadmap items are plans, not delivered security guarantees.

## 🏗️ Architecture

Kai has a small C11 core (`libkai`) with a public C API in [`include/kai.h`](include/kai.h). The CLI, hooks, installer, gateway, and macOS app build on that core. Dependencies include POSIX regex, libcurl for the gateway, and a vendored MIT-licensed copy of cJSON. See [`docs/DESIGN.md`](docs/DESIGN.md).

## 🤝 Contribute

Contributions are welcome: new detectors, integrations, documentation, and adversarial test cases. Please see [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributors sign a CLA to support the open-source and commercial licensing options.

## 📜 License and security

Kai is offered under **GPL-3.0-only** or a separate commercial license. See [`LICENSE`](LICENSE) and [`COMMERCIAL.md`](COMMERCIAL.md). “Kai” and its logo are trademarks; see [`TRADEMARKS.md`](TRADEMARKS.md).

Found a vulnerability? Please use the disclosure process in [`SECURITY.md`](SECURITY.md), not a public issue.

---

<div align="center">
  <strong>Protect what matters. Build with AI.</strong><br />
  <sub>Stay curious. Stay in control. 🛡️</sub>
</div>
