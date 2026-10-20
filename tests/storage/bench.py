# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Storage-wall overhead benchmark (manual). NOT part of `make test`.

Times ordinary, non-protected file operations from an agent session so we can
measure the per-operation cost the Endpoint Security authorization adds. Run it
twice to compare — once with the wall on (storage=log or block) and once off
(storage=off, or the extension deactivated) — and diff the medians:

    python3 tests/storage/bench.py

It never touches a protected path, so it measures the common case: the wall
sees the event, finds the process is not an attributable agent (or the path
isn't protected), and allows. That is the cost paid by every file op on the
machine, which is what "near-zero overhead" has to be judged against.
"""
import os, statistics, tempfile, time

N = 20000
d = tempfile.mkdtemp()

def timed(label, fn):
    # warm up, then time N iterations, reporting per-op microseconds.
    for _ in range(1000): fn()
    samples = []
    for _ in range(5):
        t0 = time.perf_counter()
        for _ in range(N): fn()
        samples.append((time.perf_counter() - t0) / N * 1e6)
    med = statistics.median(samples)
    print(f"  {label:28} {med:8.2f} µs/op   ({N} ops x5, min {min(samples):.2f})")
    return med

print(f"storage-wall overhead benchmark  ({N} iterations each)")
f = os.path.join(d, "plain.txt")
open(f, "w").write("hello\n")

def op_open():
    fd = os.open(f, os.O_RDONLY); os.close(fd)
def op_create_unlink():
    p = os.path.join(d, "c"); fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o600); os.close(fd); os.unlink(p)
def op_stat():
    os.stat(f)   # stat is not an ES auth event: a control for non-ES overhead

timed("open+close (AUTH_OPEN)", op_open)
timed("create+unlink (AUTH x2)", op_create_unlink)
timed("stat (no ES auth event)", op_stat)
print("\nRun with the wall on and off and compare the medians; stat is the "
      "control (ES doesn't authorize it).")
