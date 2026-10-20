# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Storage-wall overhead micro-benchmark (manual). NOT part of `make test`.

Times ordinary, non-protected file operations from an agent session and
reports avg / p95 / p99 per-op latency and throughput, so we can measure the
cost the Endpoint Security authorization adds. Run with the wall ON (extension
active) and OFF (Storage wall toggled off, so the extension deactivates and
stops intercepting) and diff.

Note: `storage=off` is NOT the same as the wall being off — the extension
stays subscribed and still authorizes every open while allowing it. To get a
true OFF baseline, deactivate the extension (Storage wall toggle off).

`stat` is a control: Endpoint Security does not authorize it, so it shows the
non-ES floor on this machine.
"""
import os, statistics, tempfile, time

d = tempfile.mkdtemp()
f = os.path.join(d, "plain.txt")
open(f, "w").write("hello\n")

def percentiles(label, fn, n=8000):
    for _ in range(1000): fn()               # warm up
    lat = []
    for _ in range(n):
        t0 = time.perf_counter_ns()
        fn()
        lat.append(time.perf_counter_ns() - t0)
    lat.sort()
    avg = sum(lat) / len(lat) / 1000.0
    p95 = lat[int(n * 0.95)] / 1000.0
    p99 = lat[int(n * 0.99)] / 1000.0
    thr = 1e6 / avg
    print(f"  {label:26} avg {avg:7.2f}  p95 {p95:7.2f}  p99 {p99:7.2f} µs   {thr:9.0f} ops/s")

def op_open():
    fd = os.open(f, os.O_RDONLY); os.close(fd)
def op_create_unlink():
    p = os.path.join(d, "c"); fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o600); os.close(fd); os.unlink(p)
def op_stat():
    os.stat(f)

print("storage-wall overhead  (per-op latency; lower is better)")
percentiles("open+close (AUTH_OPEN)", op_open)
percentiles("create+unlink (2 AUTH)", op_create_unlink)
percentiles("stat (control, no ES)", op_stat)
print("\nActive extension version is what this measures; run ON vs OFF (deactivate the")
print("Storage wall) to get the delta. stat is the non-ES floor.")
