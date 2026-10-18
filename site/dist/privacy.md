---
layout: default
title: Privacy
description: What Kai and the Kai browser extension do with your data.
permalink: /privacy/
---
<section class="page-hero"><div class="wrap"><div class="eyebrow">Privacy</div><h1 class="page-title">Your data stays on your Mac.</h1><p>Last updated October 18, 2026.</p></div></section>
<section class="section"><div class="wrap" markdown="1">

Kai is open source and runs locally. It has no Kai account, no Kai servers and no analytics. Nothing Kai sees is sent to us or to anyone else.

## The Kai browser extension

**What it reads.** On the AI chat sites it lists (ChatGPT, Claude.ai, Gemini, DeepSeek, Perplexity, Copilot, Mistral, Grok, Poe), the text you paste or are about to send in the chat box. It doesn't read other pages, other parts of those pages, your browsing history, or what the AI answers.

**Where that text goes.** Only to the Kai program on your own computer, through Chrome's native messaging, so it can be checked against your local Kai policy for secrets and company terms. It never leaves your computer because of Kai. Whether you then send it to the chat site is your choice, as it would be without Kai.

**What is kept.**

- In the extension (Chrome's local storage): three counters (messages checked, cleaned, held) and your choice of what to do when Kai isn't reachable.
- In Kai's local log on your computer: the site, what you decided (cleaned, sent anyway, held, cancelled) and which kinds of rules matched, such as "1 GitHub token". Never the message text or the secret itself.

**What is shared.** Nothing. The extension makes no network requests of its own and contains no tracking or third-party code.

**Permissions.** `nativeMessaging` lets it talk to Kai on your computer; `storage` keeps the counters and your setting. It runs only on the chat sites listed above.

## The Kai app and command-line tool

Kai checks what AI coding agents (Claude Code, Cursor, Codex) do on your computer and records its decisions in a log at `~/.kai/audit.log`, readable only by you. A decision can include a short excerpt of the command, file path or prompt, with recognized secrets and company terms removed first; you can turn excerpts off (`audit_context off`). The network wall looks at the destinations of AI agents' connections, not their content. All of this stays on your computer.

When you report a false positive with `kai report` or "Not a threat", Kai writes the report to a local file and opens a pre-filled GitHub issue in your browser. Nothing is sent unless you submit that issue yourself.

## Contact

Questions: open an issue at [github.com/sameehj/kai](https://github.com/sameehj/kai/issues). Security reports: see [SECURITY.md](https://github.com/sameehj/kai/blob/master/SECURITY.md).

</div></section>
