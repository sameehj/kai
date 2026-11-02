---
layout: post
title: The honest agent problem
description: When an agent obeys a security denial but the recovery path still hands the task back to the user.
category: Kai field notes
date: 2026-11-02 21:35:00 +0200
---

We want an agent to respect a security denial. During Kai's development, Claude Code did exactly that: it stopped when Kai denied a command and asked a person to decide. That is the right response to a real boundary. It can still leave a normal task stranded when the reason and recovery path are opaque.

We saw this during release work. GitHub operations were blocked, notarization paused, and CI logs were unreachable at different points. The agent did not try to sneak around the guard. It handed the work back. In the attack-replay work, the agent's own safety checks also resisted some test steps until they were framed as harmless fixtures. Those pauses were useful signals. They were also reminders that a test harness and a release process have to be designed for the agent's actual permissions.

The November 1 WordPress task showed the other side of the same problem. A network drop looked to Claude Code like “the connection” was down. An MCP denial told it to approve in Kai and retry, even though the approval did not resume the original call. The [postmortem](https://github.com/sameehj/kai/blob/master/docs/security/FRICTION-POSTMORTEM.md) records how a compliant agent and an unclear guard combined into a task the author eventually finished with Kai turned off.

Even publishing this blog offered a small example. Our first attempt stopped at an expired GitHub CLI login although the repository already used an SSH remote. The human pointed that out; the existing SSH authentication completed the push. The right response was to check the authorized route and finish the work, not to require a new credential by default.

## Make the denial useful to both sides

Kai's agent instructions now tell agents what a denial means, why they should not retry the stopped action another way, and when to ask the user. A useful denial also names the operation, the rule and a concrete recovery step without exposing the secret it was protecting. For an approval that is safe to grant, the goal is to ask before the tool runs or hold the work until the decision arrives, so the same action can continue. The [Never Make the Developer Rerun plan](https://github.com/sameehj/kai/blob/master/docs/security/NEVER-RERUN.md) specifies those targets.

We have not solved every recovery path. Preview 2's Internet wall watches rather than blocks, and its hook behavior still varies by agent and event. The lesson is about the whole workflow: an honest agent can obey the boundary perfectly while the product still fails the person waiting for the result.

*Next in the series: [Five ways around agent hooks]({{ '/blog/five-ways-around-agent-hooks/' | relative_url }}).*
