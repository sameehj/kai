<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->

<div align="center">
  <img src="assets/kai-logo.png" alt="Kai shield logo" width="132" />

  # Kai Preview

  ### Give AI more work, not more access.

  **macOS** · **Claude Code · Codex · Cursor** · **Open source**
</div>

## Three steps

1. **Install Kai.** One package installs the `kai` command and adds its checks to Claude Code, Codex and Cursor.
2. **Kai checks your agents and stops unwanted moves before they run**: reading your keys, sending files out, secrets in the prompts you submit. Each stop says what happened, why it matters, and what you can do.
3. **You decide what they can do, narrowly.** When Kai stops something legitimate, its message gives the exact command to run in your own terminal: one agent, one operation, one target, with an expiry.

## The Preview 1 security contract

> **Kai Preview checks supported actions inside Claude Code, Codex and Cursor before they run.** It is an extra safety layer, not isolation or OS-level enforcement: hooks run with your permissions, cover only the actions each agent reports to them, and a program the agent runs can get around them. Codex runs hooks only after you trust them.

Kai Preview checks inside your agents. OS-level protection for files and internet comes with the Kai app in an upcoming release.

## Install

**macOS 13 or later; Linux and Windows aren't supported.**

Download `Kai-Preview-<version>.pkg` from [Releases](https://github.com/sameehj/kai/releases), check it, and open it:

```sh
shasum -a 256 -c Kai-Preview-0.2.0-preview.1.pkg.sha256
spctl --assess --type install -vv Kai-Preview-0.2.0-preview.1.pkg   # "source=Notarized Developer ID"
```

The installer refreshes Kai's checks in the agents that already have them. For another agent:

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
- No OS-level enforcement in this preview.
- No browser coverage: Kai doesn't check AI chat sites in a browser (the Chrome extension was removed). `kai uninstall chrome` removes one an earlier Kai installed.
- Screen and app control: Kai stops the commands and tools it recognizes (`screencapture`, `ffmpeg`/`sox` recording, `osascript` telling any app, computer-use tools) and names the app; you allow them per app. With the Kai app, those allows are made in the app (each agent's page), not with `kai allow-capture`. A program the agent writes can call the capture APIs directly. Kai can't change macOS privacy prompts: macOS grants these permissions per app, so every agent run in Terminal, iTerm or Cursor inherits what that app holds (`kai doctor` lists them where it can read them).

## Design references

Kai is designed with reference to, and does not claim compliance with:

- [NIST SP 800-207](https://csrc.nist.gov/pubs/sp/800/207/final) (Zero Trust Architecture): explicit, per-request decisions and least privilege;
- the [Model Context Protocol specification](https://modelcontextprotocol.io/specification): MCP tool calls are named and checked per server and tool;
- the [OWASP Top 10 for LLM Applications](https://genai.owasp.org/llm-top-10/): sensitive information disclosure, excessive agency, prompt injection;
- [RFC 9325](https://www.rfc-editor.org/rfc/rfc9325) (TLS recommendations) and [RFC 9525](https://www.rfc-editor.org/rfc/rfc9525) (service identity in TLS): how the app's Internet protection names the site a connection is for.

## Roadmap

- **Next: the Kai app.** A menu-bar app with OS-level **Files** and **Internet** protection in an upcoming release (in private testing). It adds per-agent pages, decision cards, and a protected writer for Kai's rules.
- **With the app: capture inside agent process trees.** Blocking screen, microphone and camera capture tools started inside an agent's process tree through Endpoint Security, and a notice when an agent host app's privacy permissions change, where macOS provides the event on the target version.
- Later: team policy, Linux, and Windows.

Roadmap items are plans, not delivered guarantees. The historical overview (pre-v0.2, including since-removed features): [docs/OVERVIEW.md](docs/OVERVIEW.md).

## Contribute

Contributions are welcome: detectors, integrations, documentation and adversarial test cases. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributors sign a CLA to support the open-source and commercial licensing options.

## License and security

Kai is offered under **GPL-3.0-only** or a separate commercial license. See [`LICENSE`](LICENSE) and [`COMMERCIAL.md`](COMMERCIAL.md). “Kai” and its logo are trademarks; see [`TRADEMARKS.md`](TRADEMARKS.md).

Found a vulnerability? Please use the disclosure process in [`SECURITY.md`](SECURITY.md), not a public issue.
