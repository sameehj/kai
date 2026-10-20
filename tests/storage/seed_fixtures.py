# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Seed disposable PROTECTED-pattern fixtures for destructive-op tests.

Run this while the storage wall is OFF (deactivated) — creating a file whose
name matches a protect rule is itself a write the wall blocks, so it can't be
done while enforcing. Nothing here touches real secrets: everything lives
under /tmp/kai-fixtures and holds fake data.

    python3 tests/storage/seed_fixtures.py

Then reactivate the wall and run breadth_probe.py, which detects these files
and tests append / truncate / rename / delete against them (losing a fixture
is harmless; a real secret is never touched).
"""
import os, shutil

D = "/tmp/kai-fixtures"
shutil.rmtree(D, ignore_errors=True)
os.makedirs(os.path.join(D, "nested"))

# One file per destructive op (so tests don't interfere), each matching a
# default protect rule (.env, *.pem). Fake content only.
names = {
    "append":   "." + "env",
    "truncate": "secret." + "pem",
    "rename":   "config." + "env",
    "delete":   "key." + "pem",
    "read":     "nested/." + "env",
}
for op, name in names.items():
    p = os.path.join(D, name)
    with open(p, "w") as f:
        f.write("FAKE-FIXTURE-%s-NOT-A-REAL-SECRET\n" % op.upper())
# a non-protected control that destructive ops MUST still be allowed on
with open(os.path.join(D, "plain.txt"), "w") as f:
    f.write("control\n")

print("seeded fixtures in", D)
for root, _, files in os.walk(D):
    for fn in files:
        print("  ", os.path.join(root, fn))
