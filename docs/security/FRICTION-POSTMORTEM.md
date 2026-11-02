<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Friction postmortem: the Nov 1 WordPress task

**Outcome:** the author turned Kai off for Claude Code and set the Internet wall to Watch, after an ordinary
task hit three hidden gates in five minutes. A user disabling protection is a failure of Kai, scored like a
security failure (see the usability scorecard in [RECONCILED-PLAN.md](RECONCILED-PLAN.md#nov-1-corrective-change)).

**Task:** in Claude Code, in `~/Research`, change the Magic Dose price on two WordPress pages through the
WordPress MCP server `block-mcp-innermonkeylabs-com` (`npx -y @gravitykit/block-mcp`). Internet wall in
Protect, Kai's hooks installed, extension build 28–30 during the day.

## Timeline (UTC, from `~/.kai/audit.log`)

| Time | Record | What the author saw |
|---|---|---|
| 06:11, 16:53, 19:28 | Network wall blocked `innermonkeylabs.com` for Claude Code; cards raised | Nothing: no notification (a card only played a sound). The agent reported "connection down" |
| 19:28:45, 19:29:54 | Grant approved; an Allow rule created with Touch ID | The site worked; the MCP server still didn't, and the agent said only a restart would help |
| 19:40 | `registry.npmjs.org` blocked: "kept blocked: you chose Keep blocked" | Nothing. An earlier Keep blocked, permanent, stopped `npx` from starting the MCP server |
| 20:24:18–20:24:54 | **Gate 1:** `registry.npmjs.org` blocked three times, then allowed for 1 hour; the held connection "continued after your approval" after 7.7 s | Three cards for one server start |
| 20:25:22 | **Gate 2:** hook denied the MCP tool `get_page_blocks`: "Waiting for approval in Kai … Approve in Kai, then retry" | The agent stopped; approving in Kai didn't resume the call |
| 20:27:33 | Network wall blocked `github.com:22` | Another card |
| 20:28:32 | **Gate 3:** `innermonkeylabs.com` blocked again, although the Allow rule had been used at 20:24:56. The record has no `identity`: Kai couldn't verify which signed agent owned that process, and rules only match a verified identity | A site already allowed "always" was blocked |
| 20:29:06 | Policy: `set egress block->log`, confirmed in the app | The author switched the Internet wall to Watch and turned Kai off for Claude Code |

## What failed

1. **Hidden failures.** Each gate failed the agent's call without telling the user the cause and the way out
   at the moment it happened, and the agent got either nothing (network) or "approve in Kai, then retry"
   (hook), which it can't act on. Rule 2 below.
2. **Ordinary activity interrupted.** Starting an MCP server from the npm registry, reaching the user's own
   site, and `git` over ssh are ordinary. None had a specific reason to be stopped. Rule 1 below.
3. **Decisions that didn't hold.** A permanent Keep blocked chosen once, a rule that didn't apply when the
   identity couldn't be verified, a 7-day grant the agent never retried, and cards that expired unseen.
4. **No resume.** The hook gate denied and asked for a retry; Claude Code's own "ask" prompt, which continues
   the same call on approval, wasn't used.

## Fixed in this branch before the corrective change

npm registry allowed by default (npm publish recorded as a known gap), Keep blocked per session, one
notification per waiting card with Allow / Keep blocked buttons, the agent told which MCP server is blocked
and when it is allowed (`/mcp` to reconnect). The corrective change below decides what ships.

## Decision (Nov 1)

0.2.0-preview.2 ships the hooks and the Internet wall in **Watch only**: "Internet: Kai shows every
connection your agents make. Blocking arrives in the next release." Protect stays behind a developer flag
until Guard is built and passes the replay cases in the plan amendment.
