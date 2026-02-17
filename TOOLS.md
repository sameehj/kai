# Tool Usage Conventions

## External web lookups (required behavior)

When a user asks for latest/current/news/mailing-list information:

1. Use `exec` first. Do not claim capability limits before trying commands.
2. Prefer `curl` with explicit user-agent and timeout.
3. If a command fails, show the exact error output and likely cause.
4. Try at least one fallback URL or query before giving up.
5. If a site has anti-bot protection (Anubis/403 challenge), try at least one public mirror source.

## Canonical fetch command

Use this exact pattern to avoid shell quoting issues:

```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://example.com"
```

For headers/debug:

```bash
curl -I --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://example.com"
```

## lore.kernel.org workflow

1. Query target list:
```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://lore.kernel.org/lkml/?q=f:torvalds@linux-foundation.org+d:30d.."
```
2. If blocked/fails, fallback:
```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://lore.kernel.org/all/?q=torvalds+d:30d.."
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://lore.kernel.org/lkml/new.atom"
```
3. If still failing, report command stderr verbatim and then explain probable cause.

Mirror fallback when lore is blocked:

```bash
git clone --mirror https://lore.kernel.org/lkml/0 lkml/git/0.git
git --git-dir=lkml/git/0.git log --all --since='30 days ago' --author='torvalds@linux-foundation.org' --pretty='%h %ad %s' --date=short
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://marc.info/?l=linux-kernel&w=2&r=1&s=torvalds"
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://www.spinics.net/lists/kernel/"
```

Subsystem-wide inbox clone/query pattern:

```bash
mkdir -p lore-mirror
for list in lkml stable netdev bpf linux-mm regressions io-uring linux-fsdevel linux-block linux-scsi linux-nvme linux-btrfs linux-xfs linux-ext4 dri-devel amd-gfx intel-gfx kvm linux-security-module linux-hardening linux-arm-kernel linux-riscv linuxppc-dev; do
  git clone --mirror "https://lore.kernel.org/${list}/0" "lore-mirror/${list}.git" || true
done
for repo in lore-mirror/*.git; do
  git --git-dir="$repo" log --all --since='30 days ago' --author='torvalds@linux-foundation.org' --pretty='%ad %s' --date=short | head -n 5
done
```

Author verification rule (mailing-list claims):

```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://lore.kernel.org/lkml/<message-id>/raw" | sed -n '1,60p'
```

Only call it "from Linus" if `From:` shows `Linus Torvalds` or `torvalds@linux-foundation.org`.

Date attribution rule:
- Use `Date:` from the same message header.
- Do not infer dates from thread pages or summaries.

Minimal evidence command:

```bash
curl -fsSL --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) KAI/1.0' "https://lore.kernel.org/lkml/<message-id>/raw" | sed -n '1,80p' | egrep -i '^(From|Date|Subject):'
```

Argument spacing rule:
- `git clone --mirror <URL> <DEST>` requires spaces between each argument.
- If `<DEST>` contains spaces, quote it (for example `"lkml mirror/git/0.git"`).

## Prohibited fallback phrasing

Avoid generic claims like:
- "I can't access external websites"
- "I cannot pull real-time data"

Unless multiple concrete commands were attempted and failed in-session.
