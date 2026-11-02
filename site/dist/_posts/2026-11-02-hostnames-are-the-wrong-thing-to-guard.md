---
layout: post
title: Hostnames are the wrong thing to guard
description: Why asking about every unknown site breaks ordinary work and still misses dangerous paths.
category: Kai field notes
date: 2026-11-02 21:20:00 +0200
---

Our first blocking Internet wall treated an unknown hostname as a reason to interrupt. It was easy to explain as a rule and miserable to live with. A single WordPress edit reached the site's host, the npm registry and GitHub; Kai blocked each at different points. The developer eventually switched the wall to Watch to finish the task. That [incident](https://github.com/sameehj/kai/blob/master/docs/security/FRICTION-POSTMORTEM.md) made us question the unit of protection.

A hostname tells you where a connection goes. It does not tell you what is leaving, why, or whether the destination is safe for this task. `registry.npmjs.org` is needed to install a package, but it also accepts `npm publish`. GitHub is needed for a normal push, but it can also hold a public gist or a new remote. A list of allowed domains can make routine work smooth while leaving the most valuable exit routes open.

This is not just theoretical. The [Nx maintainers' advisory](https://github.com/nrwl/nx/security/advisories/GHSA-cxm3-wv7p-598c) describes a compromised publishing path and stolen credentials. [GitHub's account of Shai-Hulud](https://github.blog/security/supply-chain-security/strengthening-supply-chain-security-preparing-for-the-next-malware-campaign/) describes malicious package scripts harvesting secrets and spreading through maintainer workflows. In the [Cursor marketplace incident](https://prod.cursor.com/blog/claude-code-extension-security-notice), a malicious extension sent host details and attempted an SSH backdoor. The lesson we draw from these incidents is about the boundary: ordinary developer services and software supply chains can carry an attack too.

## Ask about a dangerous action, not every address

The design we are working toward records routine HTTPS destinations and asks when an action has a stronger risk signal: a bare IP or unusual port, a tunnel, a changed MCP server, a destructive tool, or an outbound request after the task touched a sensitive resource. An allowed service still needs scrutiny when the *action* changes. This is a plan, not what Preview 2 enforces.

There is also a limit to any network rule. A destination filter cannot tell whether a script read a private file before it connected. File protection needs a preventive operating-system decision at the file open, including when an unrecognized process acts. Kai's planned host-wide asset layer addresses that problem; Preview 2 does not include it. The [security plan](https://github.com/sameehj/kai/blob/master/docs/security/RECONCILED-PLAN.md) separates those layers and requires replay evidence before making a protection claim.

For now, Preview 2's Internet wall **watches and records; it does not block**. That is a smaller promise, but an honest one. A hostname is useful evidence. It is a poor substitute for understanding the action.

*Next in the series: [Use, don't read]({{ '/blog/use-dont-read-ssh-keys/' | relative_url }}).*
