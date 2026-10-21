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

## v11 — in-handler stage profiler (built, not yet run live)

The ES authorization callback is now instrumented so the next reactivation can
attribute the per-op overhead to a stage instead of guessing. Lock-free C
aggregator (`src/storage_prof.c`, in libkai) fed by stage timestamps in
`StorageClient.swift`.

Stages recorded per auth callback: `classify` (process classification), `path`
(path extraction from the ES event), `policy` (`kai_path_protected`), `respond`
(the `es_respond_*` call), `total` (whole callback), and `deadline_margin` (ES
auth deadline headroom at respond time). Each keeps count, exact avg, exact max,
and a power-of-two histogram for p95/p99 (percentiles reported to the nearest
bucket edge — approximate by construction).

Properties (so it is safe to leave compiled in):
- **Off by default.** Enabled only when `~/.kai/storage_timing` exists; separate
  from the filter selector; never auto-enabled. `filter=none` stays the default.
- **Hot path adds no allocation, no lock, no blocking I/O.** Counters are C11
  relaxed atomics; when disabled the Swift side skips timing entirely and the C
  recorder is a single relaxed load + branch.
- **Export carries only numbers.** A utility-queue timer writes
  `/tmp/kai-storage-timing.json` every 5 s (off the hot path) — stage counts and
  µs timings, never a path or a process name. Unit test asserts the JSON
  contains no `/`, no `.ssh`, no `.env`.

Profiler's own cost (C aggregation layer, `run_storage_tests` microbench):
**~10 ns/call disabled, ~96 ns/call enabled**. The Swift side adds a few
`mach_absolute_time` reads per stage only when enabled.

Unit coverage: `run_storage_tests` → 11 profiler checks pass (default-off,
bounded export, exact max, no-leak export, short-buffer truncation contract,
reset). Full suites: `run_tests` 106/0, `run_storage_tests` all pass. The
storage system extension compiles clean (no warnings in StorageClient.swift or
storage_prof.c); `KAI_STORAGE_VERSION` bumped 10 → 11.

Measured live timing: NOT YET COLLECTED — needs reactivation (see below).

### Minimal, safe validation sequence (v11)

Do these in order. Nothing here weakens protection or edits policy to pass.

1. **OFF baseline.** With the Storage wall toggled **off** in the menu bar
   (extension deactivated, file events unsubscribed), run `bench.py` and
   `workload.py`. This is the no-ES floor the overhead is measured against.
2. **Seed destructive-op fixtures** while still off: `seed_fixtures.py` (writes
   only under `/tmp/kai-fixtures`, fake data). Creating a `.env`/`*.pem` name is
   itself a blocked write once the wall is on, so it must happen now.
3. **Restore protection.** Toggle the Storage wall back **on**; grant Full Disk
   Access if prompted. Keep `filter=none` (default) and `storage=block`.
4. **Verify the active build** is v11: `kai status --json` shows the storage
   extension running at `0.1.0/11`.
5. **Re-run breadth tests:** `breadth_probe.py`. Expectation unchanged from v10
   (17 PASS / 1 FAIL / NOT TESTED now reduced by the seeded fixtures). The one
   FAIL — launchd-detached read — MUST still be reported as a FAIL.
6. **Collect timing.** Enable the profiler: `touch ~/.kai/storage_timing`, then
   toggle the wall off/on so the extension re-reads it. Run `workload.py`, then
   read `/tmp/kai-storage-timing.json` for the per-stage breakdown (this tells
   us how much of the per-op cost is ES round-trip vs. our handler). Remove
   `~/.kai/storage_timing` and toggle again to return to zero-overhead default.
7. **Test process filtering SEPARATELY, last.** Only after the above:
   `echo process > ~/.kai/storage_filter`, toggle off/on, rerun `breadth_probe.py`
   (especially process-mute invalidation / exec-transition race) and the timing
   collection. **Reject `filter=process` if any protected read leaks, even
   briefly.** Then restore `echo none > ~/.kai/storage_filter`.

### Unresolved security failure (carried forward, NOT fixed by v11)

**launchd-detached bypass:** an agent that submits a read via `launchctl submit`
(or an equivalent XPC/launchd detachment) is re-parented away from the agent, so
its responsible audit token is launchd and the wall does not attribute the read
back to the agent — the secret is readable. This is a release blocker and is
independent of the profiler work. Still needs a design decision (block agent
launchd/XPC submission, or accept + document).

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
