---
name: linux-kernel-mailing-list-search
description: Search and analyze Linux kernel mailing lists on lore.kernel.org for patches, discussions, regressions, and developer activity using existing public endpoints.
---

# Linux Kernel Mailing List Search

Use this skill when users ask about:
- kernel patches or patch series status
- maintainer/developer activity on lore
- subsystem discussions (netdev, bpf, mm, fs, kvm, etc.)
- regression reports and fixes

This skill is a lightweight interface to lore.kernel.org. Do not build custom indexing, local mirrors, or background sync systems.

## Core approach

1. Start with lore query URLs directly.
2. Use broad queries first, then narrow by list/author/date/subject.
3. Fetch top relevant threads/messages.
4. Return concise summaries with direct lore links.
5. Never stop after a single HTTP failure; apply fallback sequence.

## Preferred sources

- Search: `https://lore.kernel.org/{list}/?q={query}`
- Thread: `https://lore.kernel.org/{list}/{message-id}/`
- Raw message: `https://lore.kernel.org/{list}/{message-id}/raw`
- Feed: `https://lore.kernel.org/{list}/new.atom`

Use web search only when list selection is ambiguous or parsing fails.

## Mirror fallback (when lore is blocked)

If lore returns Anubis page, HTTP 403, or anti-bot challenge, do not stop.
Use read-only public mirrors and clearly label mirror source in the answer:

- `https://www.spinics.net/lists/kernel/`
- `https://marc.info/?l=linux-kernel&r=1&w=2`
- `https://www.mail-archive.com/linux-kernel@vger.kernel.org/`

Always prefer lore first, but continue with mirrors if lore is inaccessible.

## Public-inbox git fallback (preferred before third-party mirrors)

When web access to lore is blocked, use lore's public-inbox git mirror endpoint:

```bash
git clone --mirror https://lore.kernel.org/lkml/0 lkml/git/0.git
```

Then query locally (example patterns):

```bash
git --git-dir=lkml/git/0.git log --all --since='30 days ago' --author='torvalds@linux-foundation.org' --pretty='%h %ad %s' --date=short
git --git-dir=lkml/git/0.git log --all --since='30 days ago' --author='torvalds@linux-foundation.org' --pretty='%H' | head -n 20
```

If you need message body text, inspect a selected commit/message object:

```bash
git --git-dir=lkml/git/0.git show --stat --no-patch <sha>
git --git-dir=lkml/git/0.git show <sha> | sed -n '1,200p'
```

Command formatting note:
- Space is required between command arguments.
- In `git clone --mirror <URL> <DEST>`, there must be exactly one separator space between `<URL>` and `<DEST>`.
- Destination paths with spaces must be quoted: `"lkml mirror/git/0.git"`.

For subsystem-wide searches, clone multiple list inboxes with a loop:

```bash
mkdir -p lore-mirror
for list in lkml stable netdev bpf linux-mm regressions io-uring linux-fsdevel linux-block linux-scsi linux-nvme linux-btrfs linux-xfs linux-ext4 dri-devel amd-gfx intel-gfx kvm linux-security-module linux-hardening linux-arm-kernel linux-riscv linuxppc-dev; do
  git clone --mirror "https://lore.kernel.org/${list}/0" "lore-mirror/${list}.git" || true
done
```

Then query all cloned lists:

```bash
for repo in lore-mirror/*.git; do
  git --git-dir="$repo" log --all --since='30 days ago' --author='torvalds@linux-foundation.org' --pretty='%ad %s' --date=short | head -n 20
done
```

## High-priority lists

- `lkml`, `stable`, `netdev`, `bpf`, `linux-mm`, `regressions`
- `dri-devel`, `kvm`, `rust-for-linux`, `io-uring`, `linux-fsdevel`

## Query patterns

- Basic: `?q={query}`
- Author: `?q=f:{email}`
- Date range: `?q=d:{YYYYMMDD}..{YYYYMMDD}`
- Subject: `?q=s:{subject}`
- Combined: `?q={query}+f:{author}+d:{range}`

Use relative windows for recency when appropriate:
- last week: `d:7d..`
- last month: `d:30d..`

## Access pattern (required)

When using `exec` for web fetches, prefer:

```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' '<URL>'
```

If request fails, retry once with headers for diagnosis:

```bash
curl -I --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' '<URL>'
```

Do not claim "cannot access" until you run at least 2 different endpoints.

Minimum fallback sequence:
1. target list query (for example `lkml`)
2. `all` query: `https://lore.kernel.org/all/?q=...`
3. atom feed: `https://lore.kernel.org/lkml/new.atom`
4. public-inbox git clone fallback (`https://lore.kernel.org/{list}/0`)
5. mirror query (`spinics` or `marc` or `mail-archive`)
6. `site:lore.kernel.org` web search fallback

If still blocked, report exact error and likely cause (network/DNS/firewall/rate-limit/WAF), then provide direct links for manual opening.

## Message prefixes

- `[PATCH]`, `[PATCH v2]`, `[PATCH v3]`
- `[RFC]`
- `[GIT PULL]`
- `[REGRESSION]`
- `[ANNOUNCE]`

Treat these as classification hints in summaries.

## Workflows

### 1) Recent subsystem patches

1. Query subsystem list with date + patch subject filter.
2. Extract subject, author, date, thread link.
3. Group by topic if many results.

Example:
`https://lore.kernel.org/bpf/?q=d:7d..+s:PATCH`

### 2) Author activity

1. Filter by author email + date.
2. Separate posted patches vs review/comments.
3. Highlight recurring topics.

Example:
`https://lore.kernel.org/netdev/?q=f:davem@davemloft.net+d:30d..`

For Linus activity on LKML:
`https://lore.kernel.org/lkml/?q=f:torvalds@linux-foundation.org+d:30d..`

Mirror alternatives:
- `https://marc.info/?l=linux-kernel&w=2&r=1&s=torvalds`
- `https://www.mail-archive.com/search?l=linux-kernel@vger.kernel.org&q=Linus+Torvalds`

### 3) Specific topic discussions

1. Search relevant list(s) by topic keyword.
2. Open top threads for context.
3. Summarize key points and current status.

Example:
`https://lore.kernel.org/io-uring/?q=performance`

### 4) Patch series evolution

1. Search by normalized subject (drop vN markers).
2. Identify `[PATCH]`, `[PATCH v2]`, `[PATCH v3]` timeline.
3. Note visible deltas and review feedback.

### 5) Regression tracking

1. Query regressions list by date.
2. Search for `Fixes:` and affected subsystem mentions.
3. Return active issues + linked fixes/discussions.

Example:
`https://lore.kernel.org/regressions/?q=d:7d..`

## Result format

Keep output short and actionable:

1. What you searched (lists/date range/filters)
2. Key findings (bulleted or numbered)
3. Direct lore links for each finding
4. Optional next query refinement

Example style:

`Found 5 recent BPF patch threads (last 7 days):`
`1. bpf: ... — Author (date) [link]`
`2. bpf: ... — Author (date) [link]`

For requests like "latest roasting by Linus", keep tone factual:
- Quote thread subject and date
- Summarize strong criticism neutrally (no sensational phrasing)
- Include direct thread links so user can read context
- If using mirrors because lore is blocked, state: "Using mirror source due lore anti-bot block."

## Author verification (required)

Never label an item as "Linus said" unless author is verified at message level.

Verification rule:
1. Open the specific message (or `/raw` endpoint when available).
2. Confirm `From:` contains Linus identity:
   - `Linus Torvalds`
   - `torvalds@linux-foundation.org`
3. If not verified, move item to "Threads involving Linus" (not "Linus-authored").

When only thread-level evidence is available:
- Say: "Linus participation not verified at message level."
- Do not quote as direct Linus statement.

Output sections for this request type:
1. `Verified Linus-authored messages`
2. `Threads involving Linus (author not verified)`

For each verified item include:
- date
- subject
- exact message link
- one-line summary

## Evidence extraction (required)

For every claimed Linus-authored item, extract and show header evidence from the exact message:

```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://lore.kernel.org/lkml/<message-id>/raw" \
  | sed -n '1,80p' \
  | egrep -i '^(From|Date|Subject):'
```

Required response contract for "latest roasting by Linus":
1. `Verified Linus-authored messages` section must contain header evidence lines (`From`, `Date`, `Subject`) per item.
2. If header evidence is missing, do not include the item as verified.
3. If zero verified items found, explicitly say: "No Linus-authored messages verified in current result set."

Date rule:
- Use `Date:` header from the message itself.
- Never infer date from thread summaries alone.

## List mapping shortcuts

- networking: `netdev`, `bpf`, `mptcp`
- filesystems: `linux-fsdevel`, `linux-btrfs`, `linux-xfs`, `linux-ext4`
- graphics: `dri-devel`, `amd-gfx`, `intel-gfx`
- virtualization: `kvm`, `xen-devel`
- security: `linux-security-module`, `linux-hardening`
- memory: `linux-mm`
- storage: `linux-block`, `linux-scsi`, `linux-nvme`

## Subsystem list sets for git fallback

- core: `lkml`, `stable`, `regressions`
- networking: `netdev`, `bpf`, `mptcp`, `netfilter-devel`, `xdp-newbies`
- storage: `linux-block`, `linux-scsi`, `linux-nvme`
- filesystems: `linux-fsdevel`, `linux-btrfs`, `linux-xfs`, `linux-ext4`, `linux-nfs`
- graphics: `dri-devel`, `amd-gfx`, `intel-gfx`, `nouveau`
- virtualization: `kvm`, `xen-devel`
- security: `linux-security-module`, `linux-hardening`, `selinux`
- memory: `linux-mm`, `nvdimm`
- architecture: `linux-arm-kernel`, `linux-riscv`, `loongarch`, `linuxppc-dev`
- rust: `rust-for-linux`
- io: `io-uring`

## Error handling

- No results: widen date window, broaden terms, try neighboring lists.
- Too many results: narrow list/date, add `s:` or `f:` filters.
- Parsing trouble: fall back to web search and provide direct lore query URL.
- HTTP 403/429: retry with user-agent, try `all` and `new.atom`, then report exact failed command output.
- DNS/connectivity error: state this is network resolution/connectivity, not "no mailing list activity."
- Anubis/anti-bot: immediately continue with mirror fallback and still return findings when possible.

## Constraints

- No custom long-running mirror infrastructure
- Temporary per-query public-inbox clones are allowed when lore web endpoints are blocked
- No vector DB/stateful indexing
- No long-form analytics pipelines
- Stay with existing lore endpoints + lightweight parsing/summarization
