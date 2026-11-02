---
layout: post
title: Releasing when CI won't run
description: macOS runners stalled, a fake key tripped Kai's own scan, and the release record had to say what was verified.
category: Kai field notes
date: 2026-11-02 20:40:00 +0200
---

A green CI badge would have been the easiest release story. For Preview 2, GitHub's macOS jobs were cancelled before the relevant run could produce that evidence. We did not turn an absent run into a pass. The [release notes](https://github.com/sameehj/kai/blob/master/docs/release/0.2.0-preview.2.md) say plainly that GitHub CI did not run for that commit and list the local checks that did.

The test setup had its own friction. Kai scans the repository for secrets. An intentionally fake key in test material looked enough like a real credential to trip that scan. The useful fix was to create harmless fixtures at runtime and keep their scope explicit, rather than weakening the detector so the test tree looked clean. A security test that passes only after its security rule is disabled is not evidence.

The release record separates three things that are often bundled into one “verified” label. **Tree identity:** the source being tested and the source being packaged must be the intended commit, with no dirty changes quietly added. **Artifact identity:** the app, extension, CLI and package must be signed as intended, notarized, stapled and accepted by macOS. **Behavior:** the specific hook, network and repair cases must run, with failures and untested cases listed by name. The [package script](https://github.com/sameehj/kai/blob/master/scripts/release/build-preview-pkg.sh) enforces much of the first two; the release notes record the third.

That record is intentionally uneven. Several release-blocking cases passed on a previous signed build with the same code except wording. A clean-Mac replay and two checks on the final build still needed confirmation. The end-to-end attack replay had not run. Those facts narrow the release claim; they do not disappear because the package was notarized.

We still want CI on the tagged source, and the workflow is configured for macOS. When the runner is unavailable, the honest choice is either to delay or to publish a smaller claim backed by local evidence. For this preview we chose the latter, with the missing evidence in public view. “CI did not run” is a fact a user can evaluate. “Everything passed” would have been a story we could not support.

*Start the series: [I built a security tool, then turned it off]({{ '/blog/i-built-a-security-tool-then-turned-it-off/' | relative_url }}).*
