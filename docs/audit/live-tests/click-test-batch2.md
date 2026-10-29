# Click test: batch 2 and its fixes

About 40 minutes, on Sameeh's Mac, with the build from `fix/ux-review-phase-a` (network extension v22, Files extension v38). It covers every batch 2 item (B2-1 to B2-12), the five fixes (F1 to F5), and the B2/B3 clicks that were never tested.

Fill in **Result** with ✅, ❌ plus what you saw, or "skipped". Stop at the first ❌ that blocks later steps.

**Setup.**
- Use two terminals. **T1** is a plain Terminal (not an agent). **T2** runs a Claude Code session in a scratch folder (`mkdir -p /tmp/kai-click && cd /tmp/kai-click && claude`).
- "Ask Claude Code to run X" means typing in T2: *run this exact command: X*.
- Before starting, delete any rule for `example.org` in Settings → Permissions, so step 13 starts clean.

## 0. Preparation (5 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 0.1 | T1: `systemextensionsctl list \| grep sameehj \| grep activated` | Network **0.1.0/22** activated. If it still says 20 or 21, turn Internet off and on in Kai and check again. | |
| 0.2 | Kai → Settings → Files: turn Files **on**, approve if asked, set **Protect**. | The pill says **Protecting** within about 30 s. The extension list shows storage **0.1.0/38**. | |
| 0.3 | Settings → Internet: set **Protect**. | The pill says **Protecting**. | |
| 0.4 | T1: `kai doctor \| sed -n '/Extension health/,/Known gaps/p'` | Both extensions are "running … policy current". Coverage lists Files sessions attributed and Internet connections seen. | |

## 1. Popover (8 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 1.1 | Open the popover. | The header line comes from measured state ("Protected · N agents working" or the named gap). Below it are **one large number** ("1 agent working") and **one value line** ("Kai kept … today" or "Nothing risky today"). (B2-3) | |
| 1.2 | T1: `wc -c < ~/.kai/daily/$(date +%F)`. Then ask Claude Code to run `cat ~/.ssh/id_ed25519` (or any protected file). Reopen the popover and run the `wc` again. | The count goes up by 1 and the value line's "secrets private" number goes up by 1. (F1) | |
| 1.3 | Ask Claude Code to run `curl -sS -m 5 https://o1.ingest.sentry.io/`. Reopen the popover and run the `wc` again. | The curl fails. No card appears, nothing appears in **Recent**, there's no notification, and **neither the count nor the value line changes**. (B2-4, F1) | |
| 1.4 | Look at the Claude Code session row. | Its title is the topic or project; the terminal (ttys…) appears **only on line 2**. "Files + Internet" is **not shown**, because it matches the headline. (B2-5) | |
| 1.5 | Turn Files **off** in Settings (Touch ID). Reopen the popover. | The session row now shows its coverage ("Internet only"), in amber. Turn Files back **on** for the rest of the test. | |
| 1.6 | Look at **Recent**. | Plain sentences, e.g. "Claude Code tried to reach example.org. Blocked." No line says "TLS without server name", and nothing is cut off mid-word. (B2-6) | |
| 1.7 | Footer | It reads **"Pause Kai · 15 min"**, then Settings, then Quit. There's no telemetry hint anywhere in the popover. (B2-7, B2-4) | |
| 1.8 | Click **Pause Kai · 15 min**. | A banner says "Kai is paused until HH:MM. Agents aren't being checked and nothing is blocked. Files notes what it would have blocked; Internet activity isn't recorded. Kai's own settings stay protected." A notification says "Kai paused for 15 minutes". | |
| 1.9 | Open Settings → Agent Control → the Claude Code session. | **The same paused state** shows there (Paused until HH:MM, with Resume and +15 min). (B2-7) | |
| 1.10 | Click **Resume** in Settings, then reopen the popover. | The popover banner is gone too. | |

## 2. Cards (8 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 2.1 | Ask Claude Code to run `curl -sS -m 5 https://example.org`. | A card appears: "Claude Code (session …) wanted to connect to example.org". **Why?** shows "Agent: com.anthropic.claude-code (Q6L2SF6YDW), verified signature", plus Process and Session as separate lines. | |
| 2.2 | Click **Keep blocked**. Ask Claude Code to run the same curl again. | **No new card.** Activity shows a row "Claude Code tried example.org again. Kept blocked, as you chose." with **Unblock…**. (B2 remembered) | |
| 2.3 | In that Activity row, click **Unblock…**, then rerun the curl. | A card appears again. | |
| 2.4 | On the card: **More… → Create a rule…** | The sheet names Claude Code's signature, "every session from now on", "Only example.org, not its subdomains", and "Kai can't tell what is sent over this encrypted connection". | |
| 2.5 | Click **Create rule**. | Touch ID or password is asked. Afterwards there's a notification, the card is gone, and Settings → Permissions → Rules shows the rule "in every session". | |
| 2.6 | Ask Claude Code to run the curl again. | HTTP 200. Activity has "used … your rule". | |
| 2.7 | Within 30 min of 2.5: Settings → Internet → **Watch**. | **No** second Touch ID: one authentication covers 30 minutes. Set it back to **Protect** (still no prompt). | |
| 2.8 | Lock the Mac (Ctrl-Cmd-Q) and unlock it. Settings → Internet → Watch. | Touch ID is asked again, because locking resets the window. Set it back to **Protect**. | |
| 2.9 | Settings → Permissions: remove the example.org rule, then rerun the curl. | A card appears again. Removing the rule needed no Touch ID. | |
| 2.10 | Ask Claude Code to run `curl -sk -m 5 https://1.1.1.1/`. | The card says "1.1.1.1:443 (hostname unknown)". It offers only **Allow this connection** and **Keep blocked**, with no More… or rule. (B2 hostname honesty) | |
| 2.11 | Turn Files **off** (no sessions). Ask Claude Code to run `curl -sS -m 5 https://example.net`. | The card's main button reads **"Allow Claude Code to reach example.net for 1 hour"** instead of "for this session". (F2) | |
| 2.12 | Click it, then rerun the curl. | HTTP 200. Settings → Permissions → Rules shows it "until HH:MM" (an hour from now). Turn Files back **on**. | |
| 2.13 | (Optional, after an hour, or remove the rule by hand.) Rerun the curl. | It's blocked again, and the rule is gone from Settings. | |

## 3. Activity (6 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 3.1 | Settings → Activity. Find the example.org block from 2.1. | **One** row for it. No separate "Warning · Grant" row, no `id=net-…` text, no raw `(ip:port)` in the sentence. (B2-9) | |
| 3.2 | On a blocked-site row from a session that's still running: | It shows **Allow for this session** and **Create a rule…**. | |
| 3.3 | On a blocked-site row from an ended session, or one from step 2.11 (no session): | It shows **Allow … for 1 hour** (when the agent's signature was recorded) and **Create a rule…**. Rows from before this build show Create a rule greyed out, with a tooltip saying why. (B2-10, F2) | |
| 3.4 | The 1.1.1.1 row from 2.10 | Explanation only ("Nothing to allow afterwards …"). | |
| 3.5 | Ask Claude Code to run `cat ~/.kai/policy`. Find its row. | It says "Always protected" with no buttons. | |
| 3.6 | The telemetry row from 1.3 | It's in Activity (not in Recent), with **Telemetry settings**, which opens Settings → Internet. | |
| 3.7 | Ask Claude Code something containing a fake key (`ghp_` followed by 36 letters). Find the redaction row. | It offers **Not a secret** (with Report a false positive…). | |
| 3.8 | Ask Claude Code to `cat ~/.aws/credentials` (with Files in Protect), then open Activity while its card is still waiting. | That row shows the **same buttons as the card**. | |

## 4. Settings (5 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 4.1 | Settings → Internet, below the Watch/Protect/Off choice | It says "Watch and Protect both turn off QUIC for agents, so Kai can see which sites they reach. Agents fall back to normal HTTPS; in Watch nothing else is blocked." (F3) | |
| 4.2 | Settings → Internet → Agent telemetry | "Claude Code · Telemetry: blocked by Kai", with **Turn off in Claude Code**. (B2-4) | |
| 4.3 | Click **Turn off in Claude Code**. | Touch ID (or none, if within 30 min of the last one). Then "Done. Restart your Claude Code sessions …", and the row says "Turned off in Claude Code". T1: `grep -A2 '"env"' ~/.claude/settings.json` shows `"DISABLE_TELEMETRY": "1"`. `~/.claude/settings.json.kai-bak` exists. Kai's hooks are still in the file (`grep -c "kai hook" ~/.claude/settings.json` is 6 or more). | |
| 4.4 | Settings → Internet → Agent profile hosts | Cursor's hosts are listed. **workoscdn.com** is marked "observed, not documented". The others aren't marked. (F5, B2-12) | |
| 4.5 | Settings → Files and Settings → Internet pills | Each shows one word that matches the measured state (Protecting, Watching, Off, Starting, Unhealthy or Not installed). | |
| 4.6 | (Only if a build without Files is at hand: `make app-dev` instead of `app-storage`.) Settings → Files and the popover | A greyed card says "Coming in a later release", with no toggle. The popover says "Files: later release". (B2-8) Otherwise mark skipped: there's no such build on this Mac. | |

## 5. Network (5 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 5.1 | With Internet in **Protect**, use Cursor normally for 2 minutes (open a chat, ask something). | **No** "QUIC · host unknown" cards. Cursor works. Activity shows at most one "Cursor tried QUIC; Kai made it use HTTPS…" row per 10 minutes. (B2-11) | |
| 5.2 | Sign out of Cursor and sign back in. | Sign-in works without any card for x.ai, grok, workoscdn or cursorvm hosts. (B2-12) | |
| 5.3 | Ask Claude Code to run `curl -sS -m 5 https://auth.grok.com`. | **Blocked** (card). The sign-in hosts are allowed for Cursor only. | |
| 5.4 | Set Internet to **Watch** and repeat 5.1 briefly. | Cursor works. Activity shows site names (not "host unknown") for its connections. | |

## 6. Chrome and the installer (5 min)

| # | Do | Expected | Result |
|---|---|---|---|
| 6.1 | T1: `make chrome-zip`, then `unzip -p build/kai-chrome-0.1.0.zip manifest.json \| grep permissions` | `["nativeMessaging", "storage"]`, with no `tabs`. (B2-1) | |
| 6.2 | chrome://extensions → Kai → **Reload** (the unpacked copy). Open claude.ai and chatgpt.com in two tabs, then open Kai → Settings → Chats. | Both sites show as open. Close one tab and wait about 2 s: it shows as closed. Chrome never asked for "Read your browsing history". | |
| 6.3 | T1: `sh scripts/release/build-preview-pkg.sh 0.1.0 --test` | It prints `UNSIGNED test package … Kai-Preview-0.1.0-UNSIGNED-TEST.pkg`. (B2-2) | |
| 6.4 | T1: `sudo installer -pkg build/release/Kai-Preview-0.1.0-UNSIGNED-TEST.pkg -target /` | "The install was successful." This replaces `/usr/local/bin/kai` with this build. | |
| 6.5 | T1: `grep "kai postinstall" /var/log/install.log \| tail -2` | "kai postinstall: registered kai with \<you\>'s browsers". (F4) | |
| 6.6 | T1: `ls -l ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/io.github.sameehj.kai.json; sudo ls /var/root/Library/Application\ Support/Google 2>&1` | The first is owned by you, modified just now. The second is "No such file or directory": root's home was never touched. (F4) | |
| 6.7 | (Covered by `tests/release/run_postinstall_tests.sh`, no click needed.) Nobody signed in | It skips with "nobody is signed in …". | ✅ automated |

## Not in this script
- Store ID (B2-2, last part): waits for the unlisted upload's ID.
- Gate B2 failure tests (crash, restart, missed deadline): a separate script.
