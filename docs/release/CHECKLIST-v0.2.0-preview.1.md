# Release checklist: v0.2.0-preview.1

Everything here waits on Sameeh. The code side is on `fix/ux-review-phase-a`; `make test` passes except the escape case `mcp-send-data` (open item 9).

## A. Signed build (needs your Developer ID)

1. **Certificates** in your login keychain (Xcode → Settings → Accounts → Manage Certificates):
   - `Developer ID Application: <Name> (KD446VDTM2)`
   - `Developer ID Installer: <Name> (KD446VDTM2)`
   Check with `security find-identity -v -p basic | grep "Developer ID"`.
2. **Notary profile** (once): `xcrun notarytool store-credentials kai-notary --apple-id <id> --team-id KD446VDTM2` (app-specific password).
3. **Chrome store ID**: upload `build/kai-chrome-0.2.0.zip` (`make chrome-zip`) as an unlisted item and note its 32-letter ID ([CHROME_STORE.md](../CHROME_STORE.md)).
4. **Merge to master** through a PR from `fix/ux-review-phase-a` (master is never pushed to directly).
5. **Tag** the merge commit on a clean tree: `git tag v0.2.0-preview.1 && git push origin v0.2.0-preview.1`.
6. **Build** (it refuses without all four values, a clean tree and the tag, and unless the tag is `origin/master` HEAD with every CI check passed on that commit):
   ```sh
   KAI_DEVID_APP="Developer ID Application: <Name> (KD446VDTM2)" \
   KAI_DEVID_INSTALLER="Developer ID Installer: <Name> (KD446VDTM2)" \
   KAI_NOTARY_PROFILE=kai-notary \
   KAI_STORE_EXTENSION_ID=<store id> \
   sh scripts/release/build-preview-pkg.sh 0.2.0-preview.1
   ```
   It builds a Universal `kai` (macOS 13+), signs it and the package, notarizes, staples, checks with `spctl`, and writes the `.sha256`.
7. **Publish** as a pre-release: `gh release create v0.2.0-preview.1 --prerelease --notes-file docs/release/v0.2.0-preview.1.md build/release/Kai-Preview-0.2.0-preview.1.pkg build/release/Kai-Preview-0.2.0-preview.1.pkg.sha256`.

## B. Your manual checks (record results in docs/audit/preview1-contract.md)

| # | Check | How | Result |
|---|---|---|---|
| 1a | Live checks, release build, your account | From a checkout of the tag, in your own Terminal: `sh scripts/live-checks-preview1.sh`. It refuses unless both the `kai` it runs and Claude Code's Kai hook are release builds. Real `claude -p` sessions in a new temp project with fake `.env` and `id_test`; grants from the release `kai` for exact temp paths, `--for 1m`. Checks: stop · the agent relays the command · allow · retry works · upload still stopped · expiry · policy missing (here: the same commit's dev build against a temp copy of your policy, since release builds ignore `KAI_POLICY`; yours is never moved). It fingerprints `~/.kai/policy`, `policy.sha256` and `agent-rules.json` first, asks before appending to the activity log (the one thing it can't undo), removes only its own grants, deletes the temp folder and the run's Claude Code transcripts, and prints a results table with the fingerprint check. Paste the table here. Uses model quota || **PASS 9/9** (2026-10-30, commit 5c6b1bd, release build, your Terminal); table in B.1 results below |
| 1b | Live checks in a fresh macOS user account | System Settings → Users & Groups → Add User (a Standard account just for this). Log in to it, install the Kai package (and the app, if testing with it), run `claude` once to sign in, then `/usr/local/bin/kai install claude` (or let the app install the hooks). From a checkout of the tag: `sh scripts/live-checks-preview1.sh --fresh-user`. It refuses if the account has `~/.ssh/id_*` or `~/.aws/credentials`, and asks you to type the account name. It runs the same checks, plus the policy-missing check for real with the release hook: that account's policy is moved aside, then restored byte for byte (also on Ctrl-C). Delete the account afterwards if you like | |
| 2 | Product acceptance | Install the RC, run an ordinary multi-step Claude Code task, hit a legitimate stop, recover with the command from the message, finish without disabling Kai | |
| 3 | Untrusted Codex | Untrust Kai's hooks in Codex (`/hooks`), then `kai status` (Codex: Not checking), `kai demo` (self-test passes), `kai demo --live --agent codex` (fails and says why) | |
| 4 | Chats rows | Fill `tests/coverage/chats_manual.json` per site (paste, Enter, button, attach); then `VERIFIED_SITES` in `integrations/browser/popup.js` lists the proven ones | |
| 5 | Chrome popup and disconnected state | Load the extension; open two chat sites; check the popup sentence and counts; quit Kai's helper (rename `kai` briefly) and check "Not checking: Kai isn't connected" | |
| 6 | Installer pages and postinstall | Open the signed `.pkg`: welcome and readme show the contract and three steps; afterwards `grep "kai postinstall" /var/log/install.log` lists the refreshed agents | |
| 7 | Clean Mac / macOS 13 | Install on a Mac without Kai, and on macOS 13: `kai status`, `kai demo` | |
| 8 | Upgrade from 0.1.0 | Install 0.1.0, then the RC: hooks refreshed, backups present, no older-over-newer refusal | |
| 9 | Escape case `mcp-send-data` | Decide: fix, or record as a known gap in ESCAPES.md | |
| 10 | Copy review | `kai status`, `kai doctor`, the stop messages, the release notes | |
| 11 | Chrome extension version | chrome://extensions → Kai → Reload, then reload open chat tabs. The `kai status` Chats line must not say "reload"; the popover row reads "Chats · N open: …" | |
| 12 | Screenshots | `/Applications/Kai.app/Contents/MacOS/Kai --snapshot ~/Desktop/kai-shots` renders popover, Agent Control, Activity and Internet with live data | |

### B.1 results: live checks, release build (2026-10-30T14:36:58Z)

`sh scripts/live-checks-preview1.sh` at commit **5c6b1bd**, run by the owner in their own Terminal against the installed release build (`kai 0.2.0-preview.1 (release build)`, Claude Code 2.1.312). Fingerprint at start and end: policy `9b57d9b8435db0fc`, policy.sha256 `b1d19abecc47424b`, agent-rules.json absent.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | stop: the .env read is stopped | PASS | audit record, no secret in the reply |
| 2 | the agent relays the exact command | PASS | kai allow-file /private/tmp/kai-live-p1.xuXw8X/proj/.env --read --agent claude --for 1h |
| 3 | allow: release kai allow-file, exact path, 1 minute | PASS | "This grant follows this exact file: if …/proj/.env is replaced or re-linked, it stops applying. Allowed Claude Code to r…" |
| 4 | retry works within the minute | PASS | the reply has the fake value |
| 5 | upload still stopped despite the read grant (release hook, direct) | PASS | permissionDecision deny: "Kai stopped a command that uses `.env`: it…" |
| 6 | expiry: after the minute, stopped again | PASS | audit record |
| 7 | policy missing: every tool check fails closed (release hook, sandbox copy) | PASS | 12/12 tool events denied (Claude Code Read, Write, Edit, Bash, Grep, WebFetch, MCP; Codex shell, apply_patch; Cursor read, shell, MCP): "Kai can't read its rules, so it stopped th…" |
| 7b | policy missing: a prompt is let through with a warning (documented) | NOTE | systemMessage: "Kai can't read its rules, so this prompt wasn't checked. Run `kai doctor`. (Kai is not stopping your work.)" |
| 8 | cleanup: temp folder deleted | PASS | /tmp/kai-live-p1.xuXw8X |
| 9 | policy and rules fingerprint matches the start | PASS | policy 9b57d9b8435db0fc · policy.sha256 b1d19abecc47424b · agent-rules.json absent |

0 failed. Rules restored byte for byte.

## C. Release batch items (2026-10-29): check each in the installed build

| # | Item | Expected | Result |
|---|---|---|---|
| A1 | Activity log check | Activity has no audit box or Verify. Settings → Advanced → "Check activity log for edits" → "No edits found in N records. (A program with your permissions could still rewrite the whole log.)" | |
| A2 | Wording | No "risky" and no "times you had to pause Kai" anywhere (popover, Settings, installer, README, release notes) | |
| A3 | Value line | "N secrets kept private · M actions stopped today"; wraps, never truncated; third line "Most: <host>, N times · Review" only when one item dominates (≥5 and at least half of today's stops) | |
| A4 | Migration notice | One line; Review opens Agent Control | |
| A5 | Working vs idle | Run `sleep 600` from Claude Code: it stays under Working now for the whole call; goes idle 15 min after the last event | |
| A6 | Release builds | `kai version` says "(release build)"; setting the home or policy environment variables doesn't move a release build off ~/.kai | |
| A7 | Agent Control | No global pause; subtitle without "pause"; Working now / Idle / Ended are headings; no row starts with an empty line | |
| A8 | Topics | A session started with pasted text or markup shows its first real sentence | |
| A9 | Repeated stops | 3rd identical blocked attempt in one session: the message ends once with "This is waiting for the user's decision in Kai. Don't retry until they allow it." | |
| A10 | Chats | Popover "Chats · N open: …" with today's redactions; Agent Control → Chats lists sites, tabs and today's redactions, no titles; "Chats: reload the Kai extension in Chrome" when missing or outdated | |
| A11 | Telemetry | Settings → Internet → Agent telemetry: Claude Code and Codex "Turn off in <agent>"; Cursor "No setting from Cursor; Kai keeps blocking it." | |
| B12 | ⓘ buttons | Each opens its copy (value line, Working now, Idle, Watch, Protect, 1 hour, this session, always, coverage) | |
| B13 | Preview labels | "Preview" badge in popover and Settings; Preview sentence in README, installer welcome, `kai status` | |
| 16a | Screen and app control, without the app (Preview 1) | Ask Claude Code to tell Safari something with osascript: "Claude Code wants to control Safari. If this was intended: kai allow-capture --app Safari --agent claude --for 15m."; run it in your own terminal (prints the lower-assurance note) and retry: Safari goes through, Music and `screencapture` are still stopped. A screenshot names `--app screencapture`. Terminal reads "…control Terminal (commands it runs there aren't checked by Kai)". `kai doctor` → "Privacy permissions of agent host apps" (apps, or "not measured" without Full Disk Access) | |
| 16b | Screen and app control, with the app (one writer) | `kai allow-capture --app Safari --agent claude` answers "Change this in Kai". The stop says "allow it in Kai: Claude Code's page, Screen and app control". On Agent Control → Claude Code → Screen and app control: the stopped app under recent asks with Allow ▾ (15 minutes, 1 hour, 1 day); after allowing, it's listed with its end time and Remove; Remove stops it again. The Activity card offers "Allow this exact command" | |
| 16c | Terminals and System Events (run anything outside Kai's checks) | Without the app: `kai allow-capture --app Terminal --agent claude --for 1h` is refused (at most 15 minutes); `--for 15m` asks for your login password in the terminal; a wrong password allows nothing. The stop and the allow both say "(commands it runs there aren't checked by Kai)". With the app: Claude Code's page offers only "Allow 15 minutes (Touch ID)" for Terminal, iTerm, Warp, Ghostty, System Events, and asks every time; the Activity card reads "Allow this exact command for 15 minutes (Touch ID)" and asks too; after 15 minutes the command is stopped again | |
| 17 | Decision cards | Popover, Activity and Agent Control cards at their narrowest: labels "Allow this session", "Allow 1 hour", "Keep blocked", "More ▾"; stacked full width when they don't fit; no "…" in any label | |
| B14 | Docs | README order; Design references say "designed with reference to"; DESIGN.md and IMPLEMENTATION_STATUS.md current-state notes | |
