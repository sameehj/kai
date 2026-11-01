---
layout: default
title: Privacy
description: What Kai does with your data.
permalink: /privacy/
---
<section class="page-hero"><div class="wrap"><div class="eyebrow">Privacy</div><h1 class="page-title">Your data stays on your Mac.</h1><p>Last updated October 31, 2026.</p></div></section>
<section class="section"><div class="wrap" markdown="1">

Kai is open source and runs locally. It has no Kai account, no Kai servers and no analytics. Nothing Kai sees is sent to us or to anyone else.

## The Kai browser extension

Kai no longer includes a browser extension (removed October 31, 2026). Earlier versions' extension read only the
text you pasted or sent on the AI chat sites it listed and checked it with Kai on your own computer; it never sent
anything anywhere. `kai uninstall chrome` removes what an earlier Kai installed.

## The Kai app and command-line tool

Kai checks what AI coding agents (Claude Code, Cursor, Codex) do on your computer and records its decisions in a log at `~/.kai/audit.log`, readable only by you. A decision can include a short excerpt of the command, file path or prompt, with recognized secrets and company terms removed first; you can turn excerpts off (`audit_context off`). The network wall looks at the destinations of AI agents' connections, not their content. All of this stays on your computer.

When you report a false positive with `kai report` or "Not a threat", Kai writes the report to a local file and opens a pre-filled GitHub issue in your browser. Nothing is sent unless you submit that issue yourself.

## Contact

Questions: open an issue at [github.com/sameehj/kai](https://github.com/sameehj/kai/issues). Security reports: see [SECURITY.md](https://github.com/sameehj/kai/blob/master/SECURITY.md).

</div></section>
