<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->

<div align="center">
  <img src="assets/kai-logo.png" alt="Kai shield logo" width="132" />

  # Kai

  ### Zero Trust. Zero Wrappers. Zero Friction.

  **Kai checks what your agents do, and shows you where they connect.**

  **0.3.0-preview.1 · macOS 13+** · **Claude Code · Codex · Cursor** · **Open source**
</div>

**Kai is a guardrail, not a sandbox.** It checks the tool calls your agents report to it, through each agent's own hooks, and leaves everything else to the agent's own approvals. A program the agent writes and runs, or anything that doesn't go through the agent's tools, isn't checked.

## What Kai does in this release

- **Agent checks enforce where the agent calls them.** When Claude Code, Codex or Cursor asks to read your keys, `.env` files or credentials, print a saved token, change Kai's or the agents' hook settings, or send a secret out, Kai stops that tool call before it runs, and says why, with a decision ID (`kai why <id>`).
- **Kai stays out of ordinary work.** Routine MCP tools, Git, `gh`, builds and tests are left to the agent's own approvals. Kai asks only for destructive MCP tools and MCP calls that send to another host.
- **A broken Kai never stops your agent.** If Kai's program is missing, the agent keeps working, and Kai says plainly that its checks are off and its settings aren't protected. Repair is one click in the app.
- **Internet (preview), off by default.** If you switch it on, Kai records the connections agents open and blocks nothing.

| | Checked by Kai | Observed only | Not covered |
|---|---|---|---|
| Claude Code | file tools, shell commands, prompts, MCP and web-fetch calls | | scripts it writes and runs, subprocesses' own file access |
| Codex | shell commands, prompts, MCP calls | | the same |
| Cursor | shell commands, file reads, prompts, MCP arguments (secrets only) | | file writes, editor extensions |
| Network (if switched on) | | connections from agent processes | encrypted contents |

Details per agent and operation: [docs/COVERAGE.md](docs/COVERAGE.md). What still gets through: [docs/ESCAPES.md](docs/ESCAPES.md).

## What it doesn't do in this release

- Kai does not prevent other programs from reading files or sending data over HTTPS in this release. That includes scripts the agent writes and runs.
- Planted SSH keys or login items.
- Untagged editors such as VS Code.
- Exfiltration through allowed services like GitHub or npm (`npm publish` included).
- Encrypted request contents: not inspected.

**Files protection: not included in this release.**

How this release was verified: see the [release notes](https://github.com/sameehj/kai/releases). What each agent reports to Kai, and what Kai can stop: [docs/COVERAGE.md](docs/COVERAGE.md).

## Install

**macOS 13 or later; Linux and Windows aren't supported.** Works with Claude Code, Codex and Cursor.

1. **Download** `Kai-Preview-<version>.pkg` from the newest release on the [Releases page](https://github.com/sameehj/kai/releases), and double-click it. It installs the Kai app and the `kai` command.
2. **Open Kai** (Applications → Kai). It lives in the menu bar. The agent checks work without anything else. Optional: in Settings, switch on **Internet (preview): Watching — nothing is blocked**.
3. **If you switched Internet on, approve Kai's network extension** when macOS asks. This is what lets Kai see where your agents connect.
   - macOS 13–14: System Settings → Privacy & Security, then click Allow next to Kai.
   - macOS 15: System Settings → General → Login Items & Extensions → Network Extensions, then turn Kai on.
4. **Add Kai's checks to your agents** in Terminal:
   ```sh
   kai install claude      # and/or: kai install codex, kai install cursor (or: kai install all)
   kai doctor              # each agent should show a ✓
   ```
   Codex runs hooks only after you trust them: open Codex, run `/hooks`, and trust Kai's.

`kai status` shows what's checked, per agent, at any time.

### Verify the download (optional)

Download `SHA256SUMS` from the same release into the same folder, then:

```sh
shasum -a 256 -c SHA256SUMS                                  # "Kai-Preview-<version>.pkg: OK"
spctl --assess --type install -vv Kai-Preview-*.pkg          # "source=Notarized Developer ID"
```

### When Kai stops something

The message says what Kai stopped, why, and the narrow way to allow it if it was intended (one agent, one operation, one target, with an expiry); see [Allow and block, narrowly](#allow-and-block-narrowly). The agent is told the same, and to ask you instead of trying another way.

### Uninstall

1. Remove Kai's checks from your agents: `kai uninstall all` (add `--purge` to also delete `~/.kai`: your settings, log and permissions).
2. Quit Kai from its menu bar icon, then drag `/Applications/Kai.app` to the Trash **in Finder**; macOS removes Kai's network extension with it.
3. Remove the `kai` command:
   ```sh
   sudo rm -f /usr/local/bin/kai /usr/local/libexec/kai-hook
   sudo rm -rf /usr/local/share/kai
   sudo pkgutil --forget io.github.sameehj.kai.preview
   ```

All releases: [github.com/sameehj/kai/releases](https://github.com/sameehj/kai/releases). From source: `make && sudo make install` (C compiler and `make`).

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
- Files protection: not included in this release. The Internet wall observes connections and blocks nothing in this release.
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
