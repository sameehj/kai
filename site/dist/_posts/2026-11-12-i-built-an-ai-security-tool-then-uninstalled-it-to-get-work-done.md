---
layout: post
title: "I built an AI security tool. Then I uninstalled it to get work done."
description: A WordPress edit kept failing behind Kai's approvals. Turning off my own tool changed what I count as a passing security test.
category: Kai field notes
author: Sameeh Jubran
date: 2026-11-12 20:10:00 +0200
---

I felt relief when I turned off the security tool I had built. That is an uncomfortable sentence to write, but it is the most useful fact in this story.

I was trying to change a price on two WordPress pages. I had Claude Code working in my research folder, with a WordPress MCP server to make the edits. The task was ordinary: reach the site, find the blocks, change the price, check the result. Kai was supposed to make an agent safer while I did that work. Instead, I spent the session working around Kai. The [incident record](https://github.com/sameehj/kai/blob/master/docs/security/FRICTION-POSTMORTEM.md) has the timestamps and audit entries; this is what the experience meant to me.

First, the site's connection failed. Claude Code called it a connection problem. I had no useful indication in the conversation that Kai's Internet wall was holding the request. I approved the site, but that did not mean the whole task could run. The MCP server started through `npx`, which needed the npm registry. A previous “Keep blocked” decision there had stuck. Later, starting that one server produced three more cards before I allowed the registry for an hour.

The server finally came up. Then Kai stopped a WordPress tool call and told the agent to wait for approval in Kai and retry. Approval did not resume that call. The agent had to try again. Git over SSH hit another network card. Then the WordPress site was blocked again even though an “always allow” rule had just worked. Kai could not verify an identity for that connection, and its rule lookup did not apply without one. To me, “always” had become “sometimes.”

None of these decisions was about a suspicious edit. They were about the pieces needed to perform the edit: a package registry, my site, a tool call and Git. Each gate had its own vocabulary and recovery path. I could approve a connection without approving the MCP call. I could approve a call and still find that its server could not start. A failed network request looked like the site was down, not like a decision I could inspect.

I eventually switched the Internet wall to Watch and turned Kai off for Claude Code. I finished the work. That outcome matters more than any individual card. I had to lower protection to complete an ordinary task, and I knew how the tool worked. Someone with less patience would have had even less reason to leave it on.

Removing Kai completely brought its own friction. The documented path was to remove hooks with the CLI, quit and trash the app in Finder, then remove installed command files with `sudo`. The app did not provide a single uninstall that checked whether the network extension and hooks were gone. After a separate uninstall attempt, macOS still listed the extension as active. I could not treat “app deleted” as “protection cleanly removed,” either.

There was a second, sharper version of the same mistake a day later. The hook launcher depended on the `kai` executable. When that executable was missing, the launcher denied every tool call. Kai also guarded the settings an agent might edit to remove the broken hook. An agent doing normal work was trapped behind a tool that was no longer functioning. Recovery required a person in Terminal. We had designed “fail closed” as if stopping work were automatically safer. In that failure state, Kai's own checks were unavailable; the stop did not create a new independent protection boundary.

I had been looking at the wrong pass condition. A blocking test can show that a suspicious command is stopped. It cannot show that a user will keep the tool enabled through a normal working day. It cannot show that an approval takes effect at the time and scope the user expects, or that a block explains itself before the user gives up. When the easiest path to completion is to disable the guard, counting the block as a win is misleading.

Preview 2 reflected the immediate lesson in a limited way: its Internet wall shipped in Watch mode, recording observed connections without blocking them. Its hooks still check supported agent actions. Watch mode let people work, but it did not solve the design problem that Protect had exposed. The [release notes](https://github.com/sameehj/kai/releases/tag/v0.2.0-preview.2) describe that boundary.

The first redesign work is in [PR #12](https://github.com/sameehj/kai/pull/12), which is open as I write this. On that branch, a missing Kai executable lets the agent continue and reports that Kai's checks are off; routine MCP calls defer to the agent's own permissions. The branch passed its macOS build and test suites. The installed-release replay of the broken-hook case had not been reported, and these changes are not in the latest public package. I will not describe a green branch as a repaired installation.

Our acceptance criteria now include the task, not only the attack. The WordPress edit must finish with protection left at its intended setting. The same authorization should still work in a new session the next day. A stop should name the component, the reason and the action that will actually recover it. We need to count unexplained failures, forced retries and moments when a user lowers protection to get on with life. The [redesign proposal](https://github.com/sameehj/kai/pull/12) sets out those replays; they are targets until they run.

I still want Kai to stop an agent from crossing a real boundary. I also want to be able to leave it installed after lunch. This incident made those one acceptance test.

*Next: [Why “don't ask again” kept asking again]({{ '/blog/repeated-approval-prompts/' | relative_url }}). For what the current release actually checks, see the [coverage guide](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md).*
