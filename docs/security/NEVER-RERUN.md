<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Kai — Never Make the Developer Rerun

Oct 31, 2026 · Sameeh Jubran

Kai's UX goal is that normal developer work never prompts, and that a legitimate boundary never forces a rerun. Security Plan v1.0 ([RECONCILED-PLAN.md](RECONCILED-PLAN.md)) decides what Kai enforces; this spec decides how enforcement feels.

## The problem

Today a legitimate action fails first and asks later, and the developer pays for the gap:

1. The agent runs `git push`; `ssh` opens the key; the storage wall denies it.
2. The agent sees "Operation not permitted" with no reason. It often retries other ways, burning tokens, and the retries look like an attack.
3. A card appears. The developer grants access.
4. The task has already failed, so the developer reruns it: more tokens, more time, lost context.

Three root causes: Kai treats *using* a credential like *stealing* it, the OS wall can't wait for a click, and the agent never learns why it was stopped.

## Five fixes

Each fix removes one step of the fail-grant-rerun loop; together they make a prompt rare and a rerun never necessary.

### 1. Named readers: use, don't read

Each credential names the signed binaries that may open it: `ssh` and `git` for SSH keys, `aws` for `~/.aws`, `kubectl` for `~/.kube/config`, `gh` for its token. These work inside an agent's tree with no prompt. Any other reader is stopped silently and logged. This alone removes the SSH-key prompts. (Already added to Security Plan v1.0, Layer 1.)

### 2. Workflow profiles instead of host prompts

Common work is allowed by **tool plus destination**, not one hostname at a time:

- git over SSH or HTTPS to the remotes in the current repo's `.git/config`;
- package installs from the registries the repo's lockfiles name (npm, PyPI, crates.io…);
- each cloud CLI to its own API endpoints;
- Apple development tools to Apple's developer services.

Profiles are written down and shown in Settings. They're derived from what the repo declares, never learned from traffic.

### 3. Ask before acting, not after failing

For agent tool calls, Kai's `PreToolUse` hook predicts the walls' verdict from the parsed command (paths, hosts) before anything runs. If the walls would stop it, the hook asks **then**. Claude Code supports an `ask` decision from a `PreToolUse` hook, so the developer answers in place and the tool call runs once. The OS wall stays as the backstop for anything the parser misses.

### 4. Hold the connection instead of dropping it

When an agent's connection needs a decision, the network wall **pauses** the flow rather than dropping it, shows the card, and resumes it on Allow. Apple's content filter can pause TCP flows indefinitely; UDP flows are dropped after 10 seconds. The command just waits, up to its own timeout, then continues.

The storage wall can't do this: Endpoint Security authorization events have deadlines, so a file decision is immediate. That's why fix 3 asks before the command runs.

### 5. Tell the agent why

A bare "Operation not permitted" makes agents retry and work around, wasting tokens. When Kai denies a tool call, the reason goes to the agent with an instruction: *"Kai stopped reading `~/.aws/credentials`: only the aws CLI may read it. Don't retry another way; ask the user."* For denials the hook can't see (a script's file open), Kai's agent instructions file explains what Kai's denials look like and that the right move is to ask.

## What still interrupts

A prompt is reserved for a real trust change; everything else is silent or logged.

| Situation | What the developer sees |
| --- | --- |
| `git push`, `npm install`, `aws s3 ls` in normal work | Nothing |
| A script reads `~/.ssh/id_ed25519` raw | Nothing at the time; Activity records "Stopped"; the agent is told why |
| A new destination outside every profile | One card; the connection waits |
| Something writes `authorized_keys` or a LaunchAgent | One card: "Stopped" with the writer named |
| Repeats of a decided case | Nothing; one counted line in Activity |

**The card** (one screen, one decision):

> **Claude Code wants to reach `files.example.dev`** While running: `curl -T build.zip https://files.example.dev/upload` Waiting: the command continues when you choose. **[Allow for this task]** [Keep blocked] · Why?

- It shows the triggering command, which Kai already has from the hook or the process arguments.
- "Allow for this task" covers the session; durable rules stay in Settings.
- It appears as a notification you can answer without switching apps.
- "Keep blocked" is remembered, so the same request never asks twice.

## Metrics and gates

Friction is measured like a security failure: a miss is a FAIL in the replay harness, with the same evidence record.

| Metric | Target | Gate |
| --- | --- | --- |
| Prompts in a normal day (`git`, `gh`, `npm`, `pip`, cloud CLIs) with both walls on | 0 | Security Plan v1.0 usability rows |
| Reruns caused by Kai | 0 | Same |
| Agent retries after a Kai denial | 0 workaround attempts | Hook and agent-instruction tests |
| Interactive decisions in an established workflow | 3 or fewer per day | Gate B1 |
| Time from card to the command continuing | Measured; reported per release | Evidence record |

Dogfood owner: Sameeh, one working day per release, logging each prompt and whether it forced a rerun.

## Platform facts and open checks

- **Network pause:** Apple's content filter can pause a flow and resume it later with a verdict. TCP flows can stay paused indefinitely; UDP flows are dropped after 10 seconds ([Apple: pause()](https://developer.apple.com/documentation/networkextension/nefilterdataverdict/pause()), [resumeFlow](https://developer.apple.com/documentation/networkextension/nefilterdataprovider/resumeflow(_:with:))). Developers report a possible race between returning pause and calling resume ([Apple forums](https://developer.apple.com/forums/thread/660589)); test it.
- **Hook ask:** Claude Code `PreToolUse` hooks can return `allow`, `deny` or `ask` ([Claude Code hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks)).

- [ ] Confirm whether Claude Code shows a `deny` reason to the model; one report says the reason reaches only the user ([issue #15345](https://github.com/anthropics/claude-code/issues/15345)). If so, use `additionalContext` or the agent instructions file instead.
- [ ] `PostToolUse` reportedly fires only on success, so it can't explain a failed command; verify on the current version.
- [ ] Check `ask` support and timeout behavior in Codex and Cursor hooks; where missing, fall back to deny with a clear reason.
- [ ] Measure how long common clients (`git`, `curl`, `npm`) tolerate a paused connection before timing out.
