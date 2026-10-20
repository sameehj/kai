# Storage wall — measured results (per configuration)

Observed on macOS 14, team KD446VDTM2, from an agent session. Reproduce with
`tests/storage/breadth_probe.py`, `bench.py`, `workload.py`. Not CI.

## v10, filter=none (verified running 0.1.0/10, storage=block)

Adversarial breadth: **17 PASS / 1 FAIL / 6 NOT TESTED**

- PASS: reads of ~/.ssh (direct, symlink, child process, rapid post-exec,
  same-pid re-exec); directory enumeration (AUTH_READDIR); ~/.kai read
  (strict); create in ~/.ssh, ~/.kai, .env, *.pem; atomic-replace rename to a
  protected name; hard link (protected source and protected target dir);
  clonefile of a secret; non-protected control allowed.
- FAIL: ~/.ssh read via a launchd-detached process (responsible token did not
  attribute `launchctl submit` to the agent). Documented attribution gap.
- NOT TESTED: inherited fd (no ES event); process-mute invalidation (only
  under filter=process); append/truncate/rename/delete of a pre-existing
  protected file (seeding one requires a brief storage=off, not done).

Overhead (per-op, avg; `stat` control ≈ 5 µs = non-ES floor):

| op             | v6 (open-only) | v10 (full coverage) |
|----------------|----------------|---------------------|
| open+close     | 95 µs          | 104 µs              |
| create+unlink  | 92 µs          | 297 µs              |

Real workloads (wall-clock):

| workload                     | v6     | v10    |
|------------------------------|--------|--------|
| git init+500 files+commit    | 907 ms | 1103 ms|
| compile 30x cc -O2           | 3840 ms| 6779 ms|
| package churn (2000 files)   | 294 ms | 634 ms |
| create+delete 3000 files     | 712 ms | 1252 ms|

OFF baseline (extension deactivated): NOT YET MEASURED — run bench.py /
workload.py with the Storage wall toggled off.

### Path-check latency fix (commit bd0f29a) — scope correction

`kai_path_protected` was measured at ~178 µs/call in a standalone microbench
whose cwd was the VM shared folder. Root cause: the allow loop re-normalized
each allow entry per call, and a RELATIVE allow entry (default `.env.sample` /
`.env.example`) made `kai_normalize_path` call `getcwd()`, which is ~90 µs on
this shared/networked filesystem. Fixed by matching allow entries with
`path_matches` only (symmetric with the protect loop). Post-fix: **2.1 µs**
(non-protected path) / **0.95 µs** (protected path) on the full default policy.

Honest scope: this cost is only paid by callers whose cwd lives in the slow
filesystem — the **CLI and the hooks**. The storage **extension runs with
cwd `/`** (fast `getcwd`), so this was **not** the source of the ~2× workload
overhead in the table above; that overhead is the ES authorization round-trip,
still to be attributed via the OFF baseline. The microbench conflated the two.

## v10, filter=process : NOT YET TESTED
Needs: write `process` to the storage-filter file under Kai's home, reactivate
(toggle off/on). Then rerun breadth_probe (esp. process-mute invalidation /
exec-transition race) and bench/workload. Reject if any read leaks, even briefly.

## v10, filter=path : NOT YET TESTED
Same, with `path`. Known to not cover .env/*.pem anywhere.

## Standing limitations
- Inherited file descriptors: not revocable via ES (authorizes open(), not
  reads on an existing fd).
- launchd/XPC-detached processes whose responsible token isn't the agent.
- Tests can't run under storage=block (the wall blocks the test's own writes);
  run the suite with storage=off or in CI.
