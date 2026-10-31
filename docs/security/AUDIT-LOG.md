# Kai's audit log: what it keeps, where, and for how long

## Where

| File | What | Mode |
| --- | --- | --- |
| `~/.kai/audit.log` | one JSON record per decision (stopped, cleaned, asked, an exception you made), hash-chained | 0600 |
| `~/.kai/audit.log.1` | the previous log, after a rotation | 0600 |
| `~/.kai/daily/<YYYY-MM-DD>` | one byte per counted record, for "N actions stopped today" (no content) | 0600, folder 0700 |

`~/.kai` is 0700. Kai sets 0600 on every write, also on a log an earlier version left wider.

## What a record holds

- What was decided, by which agent, the reason code, and when.
- **A redacted excerpt** of what triggered it: the command, path or host. Secrets in it are replaced
  with `[REDACTED by Kai …]` before the record is written; tokens never reach the file, from a command
  or from a tool's output. Turn excerpts off with `audit_context off` in the policy.
- **Never a prompt.** A prompt Kai stopped is recorded as "(prompt, N characters - not kept)", with no
  words of it, redacted or not.
- No file contents, and no allowed tool calls (normal work isn't logged).

## Rotation and retention

- The log rotates at **8 MiB** to `audit.log.1`. One old file is kept, so at most about 16 MiB of
  history is kept. The next rotation replaces `audit.log.1`.
- The size is fixed in release builds: `KAI_AUDIT_MAX_BYTES` from the environment is ignored, so an
  agent can't force rotations to push history out. Dev and test builds honour it.
- The daily counter files are a few bytes per day and are kept until `kai uninstall all --purge`.
- `kai uninstall all --purge` removes `~/.kai` (log, counters, policy, permissions). Without
  `--purge`, uninstalling keeps them.

## Checking it

- `kai log verify` checks the hash chain of `audit.log` and its link to `audit.log.1`: the new log
  starts with a "rotate" record naming the old file's last hash. An edit to either file, before or
  after a rotation, makes it report BROKEN.
- `kai status` shows "Audit log: Healthy (N records, chain intact)" or "BROKEN: <why>".
- `kai log tail` and `kai log show` print records; `show` prints them in words.

Tests: `tests/storage/run_storage_tests.c` (`test_audit_no_prompts`, `test_audit_privacy_files`,
`test_audit_rotation_chain`), `tests/release/run_release_env_tests.sh` (rotation size ignored in
release builds).
