<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai for testers (0.3.0-preview.1)

Thanks for trying Kai. This page covers everything you need for the study.

## Install

1. Install the `.pkg` you were given. It installs the Kai app, the `kai` command and the hook launcher.
2. Open **Kai** from Applications. It lives in the menu bar.
3. In Terminal, add Kai to your agents: `kai install claude`, `kai install cursor`, `kai install codex` (only the ones you use). Then run `kai doctor`.
4. Restart your agent sessions so they load the hooks. The menu bar should say **Checking**.

## What Kai checks

Kai runs inside your agents' own hooks. Before Claude Code, Codex or Cursor runs a tool, Kai looks at it and stops it when it would:

- read your keys, `.env` files or cloud credentials;
- print a saved token or password (`gh auth token`, `git credential fill`, `security … -w`);
- change Kai's settings or the agents' hook settings;
- send a secret in a prompt or tool call.

It also asks before destructive MCP tools (delete, publish, users) and MCP calls that send to another host.

Everything else is left to your agent's own approvals. That includes ordinary MCP tools, Git, `gh`, builds and tests.

## What Kai doesn't check

- Programs or scripts the agent writes and then runs: Kai sees only `python3 script.py`, not what the script opens.
- What the agent's subprocesses do on their own, and editor extensions.
- Network traffic, unless you switch on **Internet (preview)** in Settings. Even then it only watches: nothing is blocked.

Kai is a guardrail, not a sandbox.

## When Kai stops something

- **Read the message.** It names what was stopped and why, and gives a decision ID like `k-1a2b3c4d`.
- **See the details.** Click the stop in Kai's menu, then **Why?**, or run `kai why k-1a2b3c4d`. The details show what a retry would get now.
- **If the stop was wrong,** click **Not right** in the Why sheet, or run `kai not-right k-1a2b3c4d`. This is the most useful thing you can tell us.

## Pause, repair, uninstall

- **Pause:** Kai menu → **Pause 15 min**. It resumes by itself. Kai's own settings stay protected while it's paused.
- **Repair:** if the menu bar turns red ("Kai's checks are off; its settings aren't protected"), click **Repair**. It may ask for your password once. Your agents keep working while Kai is broken; they just aren't checked.
- **Uninstall:** Kai → Settings → **Uninstall**. It removes the hooks, the Internet filter and Kai's program, checks each step, and lists anything left (sometimes "Restart needed"). Then move Kai.app to the Trash.

## Sharing your stats

At the end of the study, run:

```
kai stats --export > kai-stats.json
```

The file holds counts only, per day and per agent:
- stops, asks and warnings;
- "Not right" marks;
- calls that went unchecked;
- pauses and how long they were for;
- uninstalls and repairs;
- which agents Kai is checking today.

It has no prompts, file paths, commands, code or website names. Look at it before you send it. Kai never sends anything by itself.
