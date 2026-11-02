---
layout: post
title: Never say “Protected” without a measured boundary
description: How a misleading Internet label and a Redact promise changed the words in Kai's security UI.
category: Kai field notes
date: 2026-11-02 21:00:00 +0200
---

A green shield can answer the wrong question. It may tell you a switch is on while saying nothing about what happened to the last file read or connection. During Preview 2 review, we found an “Enforced: Internet only” label even though the release's Internet wall was set to Watch. The words made observation sound like blocking.

We changed the status language to **Checking**, **Watching, not blocking**, and **Not included**. Those describe what a user can expect now. Preview 2 can deny supported agent tool calls; its Internet wall records observed connections; operating-system Files protection is absent. The [UI change log](https://github.com/sameehj/kai/blob/master/docs/release/NEXT-UI.md) records the shipped labels and the work still open.

The same discipline applies to individual events. Our [security plan](https://github.com/sameehj/kai/blob/master/docs/security/RECONCILED-PLAN.md) defines three outcomes for future enforcement and remediation:

- **Stopped:** an enforcing component confirmed denial before the action completed.
- **Restored:** the attempted repair was verified, not merely started.
- **Observed:** Kai recorded the action but did not prevent or reverse it.

That vocabulary is a design rule, not a claim that Preview 2 ships a full three-outcome remediation system. A blocked connection should not be called stopped when the wall merely logged it. A removed LaunchAgent should not be called restored if it may already have run.

We also learned that a button labelled “Redact” can promise more than its integration can deliver. Some agent hooks can deny a submitted prompt, but they cannot rewrite every prompt or every byte a tool sends. An accurate UI must say which content it can change, which action it can deny and which traffic it only sees. The [coverage matrix](https://github.com/sameehj/kai/blob/master/docs/COVERAGE.md) is the longer answer behind each short label.

There is a practical reason for this precision. When a security tool says “protected” and a script still reads a file, the user loses trust in every other status it shows. A narrower status makes it possible to make a real decision: keep Kai's agent checks on, inspect the observed connection, and understand where another control is needed.

*Next in the series: [Shipping an open-source macOS security tool]({{ '/blog/shipping-an-open-source-macos-security-tool/' | relative_url }}).*
