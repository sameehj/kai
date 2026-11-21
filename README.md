<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->

<div align="center">
  <img src="assets/brand/kai-logo-purple-teal.png" alt="Kai shield logo" width="132" />

  # Kai

  ### Your Mac's local AI agent security guard.

  **Kai checks what your agents do, and shows you where they connect.**

  **0.4.1-preview.1 · macOS 13+** · **Claude Code · Codex · Cursor** · **Open source**
</div>

**Kai is a guardrail, not a sandbox.** It checks the tool calls your agents report to it, through each agent's own hooks, and leaves everything else to the agent's own approvals. A program the agent writes and runs, or anything that doesn't go through the agent's tools, isn't checked.

## New in 0.4

- **One Kai window:** Activity (what Kai recorded in a workspace today, grouped, with the evidence behind each row), Agents, Decisions, and Ask Kai.
- **Ask Kai** answers from Kai's records only, such as "What did Kai stop?" or "Is Cursor connected?". Each answer says what it's based on, and "No matching record" never means it didn't happen. A model, if you pick one, only rewords the answer.
- **Activity recording** (on by default since 0.4.1; turn it off in Settings → General): which files agents read or changed and which commands they asked to run. Kai records metadata only, kept for 7 days.

<!-- Screenshots for 0.4 (to add): assets/screenshots/window-activity.png, window-ask.png, popover-0.4.png -->

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

## The menu-bar app

Kai lives in the menu bar. Click it to see:

<p align="center">
  <img src="assets/screenshots/popover.png" width="360" alt="Kai's menu-bar popover: the status reads Partly checking, with Claude Code and Cursor checked and Codex not checked; a link to the coverage screen; and a recent stop where Claude Code was stopped reading a demo secrets file, with Dismiss, Open Activity and Why? buttons." />
</p>

- **Status:** **Checking** (every agent you set up is checked), **Partly checking** (some agents or checks aren't active, or only warn), or **Not checking** (Kai is paused or broken). The line under it says which.
- **Recent stops:** what Kai stopped, in plain words. **Why?** opens the decision: what was stopped and why, **Retry would now be** (what Kai would decide if the agent tried again now), and the narrow way to allow it. **Not right** marks a stop you think was wrong, so it's counted for the study.
- **Coverage: what Kai checks, and what it can't see:** per agent, what's checked, what's only observed, and what isn't covered.
  <p align="center">
    <img src="assets/screenshots/coverage.png" width="640" alt="Kai Settings, Agent Control: Coverage now lists Claude Code and Cursor as Checking, Codex as Not installed, Internet as Unknown, encrypted request contents as Not inspected and Files as Not included; below, each agent session Kai sees, with its coverage and permissions." />
  </p>

- **Repair:** if the menu bar turns red ("Kai's checks are off"), one click puts back Kai's program and hook launcher. It may ask for your password once.
- **Settings → Uninstall:** the only way to remove Kai (see [Uninstall](#uninstall)).

The same from Terminal: `kai why <id>` explains a decision, `kai not-right <id>` marks it as wrong, and `kai stats --export` writes the study summary (counts only, no prompts, paths, commands or code) for you to review and send.

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

Download `Kai-Preview-<version>.pkg.sha256` from the same release into the same folder, then:

```sh
shasum -a 256 -c Kai-Preview-<version>.pkg.sha256            # "Kai-Preview-<version>.pkg: OK"
spctl --assess --type install -vv Kai-Preview-<version>.pkg  # "source=Notarized Developer ID"
```

### When Kai stops something

The message says what Kai stopped, why, and the narrow way to allow it if it was intended (one agent, one operation, one target, with an expiry); see [Allow and block, narrowly](#allow-and-block-narrowly). The agent is told the same, and to ask you instead of trying another way.

### Uninstall

**Uninstall only from Kai → Settings → Uninstall.** It removes your agents' hooks, the Internet filter and Kai's program, checks each step, and lists anything left (sometimes "Restart needed"). Then move Kai.app to the Trash.

If the app is already gone, run `kai uninstall all` in Terminal to remove Kai's hooks from your agents, then reinstall Kai and uninstall from Settings, or [contact us](https://github.com/sameehj/kai/issues).

**Don't delete Kai's files by hand** (for example `sudo rm` of `/usr/local/bin/kai` or the hook launcher). That leaves your agents' hooks behind: they keep working, but nothing is checked, and each call shows "Kai is missing: its checks are off".

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
