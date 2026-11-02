---
layout: post
title: "Use, don't read: the SSH-key lesson"
description: A live Git push showed how a credential can be used without handing its private bytes to an agent.
category: Kai field notes
date: 2026-11-02 21:10:00 +0200
---

One of our early storage-wall tests made `git push` feel like a request to steal an SSH key. The agent ran Git, `ssh` needed a credential, and the wall denied the file open. The agent saw “Operation not permitted,” a card arrived later, and approving it could not restart the failed push. The [Never Make the Developer Rerun plan](https://github.com/sameehj/kai/blob/master/docs/security/NEVER-RERUN.md) begins with that failure.

The useful distinction is between **using a credential** and **reading its private bytes**. Git should be able to authenticate to the repository you chose. A general-purpose file read of the private key should still be denied. Treating both as the same file access creates prompts for ordinary work and encourages broad exceptions.

We got one concrete result in a development build with both experimental walls enforcing. `git ls-remote` succeeded, and a `git push` completed the SSH handshake with zero Kai cards. In that run, `ssh-agent` supplied the identity; the private key file was not opened by the pushing process. The [live test note](https://github.com/sameehj/kai/blob/master/docs/audit/live-tests/item1-ssh-live.md) records exactly that. It is evidence for this path on that Mac, not proof that every Git client and key setup works.

The longer-term policy is more explicit: name the trusted readers and operations for each credential, and guard the raw key against other readers at the operating-system level. That would let a legitimate `ssh` operation proceed while a generic file-copy attempt is denied. The [security plan](https://github.com/sameehj/kai/blob/master/docs/security/RECONCILED-PLAN.md) calls for this host-wide asset layer, including processes Kai does not recognize as agents.

There is an important trade-off. If an agent can use your Git identity, it may still push code or perform other actions that identity permits. Keeping the key bytes private limits credential theft and reuse elsewhere; it does not make every authenticated action safe. Repository scope, command context and human approval for destructive operations still matter.

**Preview 2 does not ship the operating-system Files wall or named-reader policy.** Its hooks can deny supported reads inside agents, but a script can bypass them. The [current coverage matrix](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md) describes that gap. The live SSH result is a design clue for the next protection layer, not a current product guarantee.

*Next in the series: [Never say “Protected”]({{ '/blog/never-say-protected/' | relative_url }}).*
