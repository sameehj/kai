<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->

<div align="center">
  <img src="assets/kai-logo.png" alt="Kai shield logo" width="132" />

  # Kai

  ### Zero Trust. Zero Wrappers. Zero Friction.

  **Turn off your agent's permission prompts. Kai stops it reading your secrets or sending data where it shouldn't.**

  **Preview 2 · macOS 13+** · **Claude Code · Codex · Cursor** · **Open source**
</div>

## What Kai stops

- **Your agent's own secret reads and uploads**: Claude Code, Codex and Cursor reading your keys, `.env` files and credentials, or sending them out, stopped before the tool call runs.
- **Agent traffic to unknown hosts, bare IPs and odd ports**, once you turn on Protect: the Kai app's Internet wall checks each connection an agent opens and asks you about one it doesn't know. Kai starts in Watch, which records these connections and blocks none.

## What it doesn't stop in this release

- Files read or written by scripts the agent writes.
- Planted SSH keys or login items.
- Untagged editors such as VS Code.
- Exfiltration through allowed services like GitHub or npm.

**Files protection: not included in this release.**

Evidence for this release: the agent checks were verified live with Claude Code 2.1.312 (9 of 9 checks PASS, 2026-10-30) and with synthetic hook events for Codex and Cursor ([docs/COVERAGE.md](docs/COVERAGE.md)); the Internet wall's decisions (unknown host, bare IP, non-web port, no loadable policy) by tests. The end-to-end replay of attack cases has not run for this release: NOT COVERED.

## First steps

1. **Turn on Protect in Kai → Internet.** Kai starts in Watch: it records agent connections but blocks none until you do. (First install the package and approve the Internet wall when macOS asks: see [Install](#install).)
2. **Check it:** `kai install all`, then `kai doctor` and `kai status`.
3. **You decide, narrowly.** When Kai stops something legitimate, it tells you why and what to do: one agent, one operation, one target, with an expiry. The agent is told why, and to ask you instead of trying another way.

Kai is an extra safety layer, not isolation: the agent checks run with your permissions and cover the actions each agent reports to them; the Internet wall sees connections, not what a program does with your files.

## Install

**macOS 13 or later; Linux and Windows aren't supported.**

Download `Kai-Preview-<version>.pkg` from [Releases](https://github.com/sameehj/kai/releases), check it, and open it:

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type install -vv Kai-Preview-0.2.0-preview.2.pkg   # "source=Notarized Developer ID"
```

It installs the Kai app (with its Internet wall) and the `kai` command. Open Kai, approve the Internet wall when macOS asks (System Settings → Privacy & Security, or General → Login Items & Extensions → Network Extensions), then **turn on Protect in Kai → Internet**. The installer refreshes Kai's checks in the agents that already have them. For another agent:

```sh
kai install claude      # or codex, cursor, all
kai status              # what's checked, per agent
```

Codex runs hooks only after you trust them: open Codex, run `/hooks`, and trust Kai's. From source: `make && sudo make install` (C compiler and `make`).

## See it work

```sh
kai demo          # each installed agent's real hook, on a temporary fake secret
kai demo --live   # a real agent session reads the fake secret, and Kai's log confirms the stop
                  # (uses the agent and its model quota)
```

`kai demo` shows the hook works when called. `kai demo --live` also shows the agent calls it, and sets *Live verification* in `kai status`.

## Allow and block, narrowly

Run these in your own terminal; agents can't.

```sh
kai allow-file ./.env --read --agent claude --for 1h      # the file tool may read this exact file
kai allow-fetch docs.example.org --agent claude --for 1h  # the agent's fetch tool may use this host
kai allow-mcp notion search --agent claude --for 1h       # one MCP tool (or every tool of a server)
kai allow-upload ./report.pdf --to files.example.com --agent claude --for 1h
kai allow-capture --app Safari --agent claude --for 15m   # screen and app control, one app
kai block paste.example.org                               # stop commands and fetches that reach it
kai rules                                                 # what each agent may do, and why
kai undo                                                  # take back the last change
```

Every grant is one agent, one operation, one target, with an expiry. A file grant follows that exact file: if it's replaced or re-linked, the grant stops applying. A read grant doesn't allow writing or uploading the file. `allow-fetch` governs only the agent's fetch tool, never other connections to that host.

## What's checked

Exactly what each agent reports to Kai, at which stage, whether Kai can stop it, the known bypasses, and the evidence (live or synthetic): **[docs/COVERAGE.md](docs/COVERAGE.md)**. `kai status` shows the same per agent: Installed, Configured, Trusted, Self-test and Live verification.

## Known limits

- Hooks run with your permissions. A program an agent writes and runs, or a detached process, can get around them.
- Kai checks only what an agent reports to its hooks: not tool results, not the agent's other model traffic.
- Kai's rules and policy are files a program with your permissions can edit. Kai notices some policy changes made outside Kai (`kai doctor`), never all, and prevents none.
- Files protection: not included in this release. The Internet wall is the only OS-level protection, and it covers connections only.
- No browser coverage: Kai doesn't check AI chat sites in a browser (the Chrome extension was removed). `kai uninstall chrome` removes one an earlier Kai installed.
- Screen and app control: Kai stops the commands and tools it recognizes (`screencapture`, `ffmpeg`/`sox` recording, `osascript` telling any app, computer-use tools) and names the app; you allow them per app. With the Kai app, those allows are made in the app (each agent's page), not with `kai allow-capture`. A program the agent writes can call the capture APIs directly. Kai can't change macOS privacy prompts: macOS grants these permissions per app, so every agent run in Terminal, iTerm or Cursor inherits what that app holds (`kai doctor` lists them where it can read them).

## Design references

Kai is designed with reference to, and does not claim compliance with:

- [NIST SP 800-207](https://csrc.nist.gov/pubs/sp/800/207/final) (Zero Trust Architecture): explicit, per-request decisions and least privilege;
- the [Model Context Protocol specification](https://modelcontextprotocol.io/specification): MCP tool calls are named and checked per server and tool;
- the [OWASP Top 10 for LLM Applications](https://genai.owasp.org/llm-top-10/): sensitive information disclosure, excessive agency, prompt injection;
- [RFC 9325](https://www.rfc-editor.org/rfc/rfc9325) (TLS recommendations) and [RFC 9525](https://www.rfc-editor.org/rfc/rfc9525) (service identity in TLS): how the app's Internet protection names the site a connection is for.

## Roadmap

- **Next: Files protection.** OS-level protection for files, closing the gap left by scripts an agent writes, is not included in this release (in private testing).
- **With the app: capture inside agent process trees.** Blocking screen, microphone and camera capture tools started inside an agent's process tree through Endpoint Security, and a notice when an agent host app's privacy permissions change, where macOS provides the event on the target version.
- Later: team policy, Linux, and Windows.

Roadmap items are plans, not delivered guarantees. The historical overview (pre-v0.2, including since-removed features): [docs/OVERVIEW.md](docs/OVERVIEW.md).

## Contribute

Contributions are welcome: detectors, integrations, documentation and adversarial test cases. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributors sign a CLA to support the open-source and commercial licensing options.

## License and security

Kai is offered under **GPL-3.0-only** or a separate commercial license. See [`LICENSE`](LICENSE) and [`COMMERCIAL.md`](COMMERCIAL.md). “Kai” and its logo are trademarks; see [`TRADEMARKS.md`](TRADEMARKS.md).

Found a vulnerability? Please use the disclosure process in [`SECURITY.md`](SECURITY.md), not a public issue.
