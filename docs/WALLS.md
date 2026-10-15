# Kai Walls: macOS system extensions (storage + network)

*Design, October 2026. Decision: no `kai run` wrapper. Enforcement is
system-wide through Apple system extensions, approved once in System Settings,
then invisible. You start `claude`, `cursor` or anything else the usual way.*

## The promise

Install `Kai.app`, approve its extensions once in System Settings, and from
then on every agent process, and everything it starts, is subject to Kai's
file and network walls. It's the same one-time approval that Santa, LuLu and
other endpoint tools ask for.

## The two walls

| Wall | Apple framework | Entitlement | Apple approval |
|---|---|---|---|
| **Network:** where agent data can go | Network Extension (content filter) | `com.apple.developer.networking.networkextension` | No, self-service with a paid Developer Program account |
| **Storage:** what agents can read | Endpoint Security | `com.apple.developer.endpoint-security.client` | **Yes**, requested from Apple; takes weeks |

The network wall ships first. Apply for Endpoint Security now so the storage
wall isn't blocked when we reach it.

## One app, three signed pieces

```
Kai.app  (Developer ID signed + notarized, direct download)
├── Contents/MacOS/Kai                    menu-bar app: status, switches, settings, notifications
├── Contents/Library/SystemExtensions/
│   ├── <id>.networkd.systemextension     NEFilterDataProvider (egress wall)
│   └── <id>.storaged.systemextension     Endpoint Security client (storage wall)
└── libkai (static)                       the shared policy engine, linked into both
```

The extensions hold no policy logic. They turn an OS event into a `libkai` call
and enforce the answer. One policy file drives the hooks, the gateway and both
walls.

## Network wall

### Who is an agent

`kai_process_agent(policy, pid)` walks the parent chain from the flow's process
and matches each process against the policy's `agent` lines:

- **`team`:** code-signing Team ID, which survives updates. Cursor is
  `VDXQ22DGB9` and Codex is `2DC432GLL2`.
- **`exe`:** executable path glob.
- **`arg`:** any argv element. This is needed for Claude Code, which runs
  under `node`, so its executable is `node` and only its arguments show
  `…/claude-code/…` or `~/.claude/local/…`.

The network wall needs no Endpoint Security for this. The extension gets the
pid from the flow's audit token and walks the parents itself.

**Known gap:** a child that detaches and is re-parented to `launchd` loses its
link to the agent. The Endpoint Security extension closes this later, because
it sees every exec and fork and can tag the tree as it forms.

Apple's own `CursorUIViewService` contains "Cursor" in its name. Matching on
names alone would be wrong, and a unit test guards this.

### The egress decision

`NEFilterDataProvider` sees every new flow:

1. Find the owning process from the audit token. If it isn't an agent tree,
   allow the flow and stop looking at it.
2. Find the hostname. The flow often carries only an IP address, because most
   tools resolve the name and then connect to the IP. So peek the first
   outbound bytes and read the **SNI** from the TLS ClientHello with
   `kai_tls_sni`. Plain HTTP uses the `Host` header, and the flow's own
   hostname is used when present.
3. `kai_egress_allowed(policy, host)`:
   - allowed → pass
   - not allowed, `egress log` → pass and record in the audit log
   - not allowed, `egress block` → drop and record
4. QUIC/UDP 443 from agent trees is dropped in `block` mode. Clients then fall
   back to TCP, where the SNI is visible.

The default mode is **`log`**, so you can see what your agents actually reach
before tightening to `block`. The built-in allowlist covers model APIs, Cursor's
backend, GitHub/GitLab and the main package registries. Each entry also covers
its subdomains.

**Limit:** an allowlist can't stop exfiltration *to* an allowed host. An agent
holding a GitHub token can still create a gist. Content-level controls (the
gateway and hooks) and token scoping cover that.

### AI traffic: the gateway, not a transparent proxy

A transparent proxy gets the agent's TLS connection still encrypted. Reading
the prompt would mean presenting our own certificate, with a local CA trusted
in the keychain. That is man-in-the-middle, which we don't do by default.
Instead:

- **`kai gateway`** is a local server (`127.0.0.1:8787`) that agents use
  through their base-URL settings:
  - `ANTHROPIC_BASE_URL=http://127.0.0.1:8787` for Claude Code and the
    Anthropic SDKs
  - `OPENAI_BASE_URL=http://127.0.0.1:8787/openai/v1` for Codex and the OpenAI
    SDKs
  - `…/openrouter/api/v1` for OpenRouter clients

  It cleans every string in the request (redact, replace, block), forwards
  over HTTPS with the caller's own key, and streams the reply back untouched.
- **Cursor** sends prompts to Cursor's servers, not to a model API, so the
  gateway can't see them. Its prompts are cleaned by Cursor's hooks (v0.1). A
  man-in-the-middle adapter is a possible later opt-in, but Cursor may pin
  certificates.
- **Enforcement (later):** once the gateway is set up for an agent, the filter
  can drop that agent's *direct* connections to model APIs, so it can't skip
  the gateway.

## Storage wall (when the entitlement arrives)

- An ES client subscribed to `NOTIFY_EXEC`/`FORK`/`EXIT` builds the process
  tree, tagging agents and their descendants by audit token: pid plus
  pidversion, never the pid alone.
- On `AUTH_OPEN` from a tagged process, call `kai_path_protected` on the real
  path ES reports. `/var` → `/private/var` symlinks are already resolved there.
- Use inverted path muting (`es_invert_muting`, macOS 13+) so the client wakes
  only for protected prefixes, not every `open()` on the machine.
- **Deadlines:** the handler must be microseconds, using a cached tag lookup
  and a precompiled match. If a decision can't be made before the deadline,
  answer **deny** for protected prefixes and **allow** otherwise.
- **No "rule that survives a crash":** ES has none. If the client dies, nothing
  enforces until launchd restarts it. "Fail-closed" means the deny-on-deadline
  rule above plus a fast restart, not a lasting rule.
- Needs Full Disk Access, granted at approval or preset by MDM.

## Signing and setup

- A paid Apple Developer Program account. The Network Extension capability
  isn't available to free accounts.
- For development: an "Apple Development" certificate and a macOS provisioning
  profile with the Network Extension capability, plus
  `systemextensionsctl developer on`.
- For distribution: a **Developer ID Application** certificate, Hardened
  Runtime and notarization.
- Approval: macOS 14 shows it under Privacy & Security; macOS 15+ under General
  → Login Items & Extensions.
- MDM: `SystemExtensions` + `WebContentFilter` (+ TCC for Endpoint Security)
  payloads pre-approve everything for a fleet.

## Status

| Piece | State |
|---|---|
| Agent identity (`agent` lines, `kai agent-of <pid>`) | Done, tested on live processes |
| Egress allowlist (`egress`, `egress_allow`) | Done, tested |
| SNI parser (`kai_tls_sni`) | Done, fuzz-style tests under ASan |
| AI gateway (`kai gateway`) | Done, end-to-end tests with a fake upstream |
| Network extension (Xcode project, signing) | Next, needs the paid account's signing set up |
| Endpoint Security extension | After Apple grants the entitlement |
