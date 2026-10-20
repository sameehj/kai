# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Storage-wall breadth probe (manual, live). NOT part of `make test`.

Run from an agent session with the storage wall active:  python3 tests/storage/breadth_probe.py

It exercises reads/writes/renames/deletes and several access vectors against
protected and non-protected paths, and prints a matrix of
expected / actual / mechanism / PASS-FAIL. It is written to be safe:
  - never writes bytes into, renames, or deletes a REAL protected file;
  - write-protection is probed by trying to CREATE a brand-new probe file
    (O_CREAT|O_EXCL) in a protected location, then removing it if it appears;
  - destructive lifecycle ops run only on disposable files under /tmp.
Paths are built from fragments so a protected name never appears literally.
"""
import os, subprocess, sys, tempfile, time, pathlib

HOME = pathlib.Path.home()
SSH = HOME / ("." + "ssh")
KAI = HOME / ("." + "kai")
rows = []

def record(scenario, expected, blocked, mechanism, note=""):
    # expected: True = should be blocked. blocked: True = was denied (EPERM).
    if blocked is None:
        verdict = "NOT TESTED"
    else:
        verdict = "PASS" if blocked == expected else "FAIL"
    rows.append((scenario, "block" if expected else "allow",
                 "n/a" if blocked is None else ("blocked" if blocked else "allowed"),
                 mechanism, verdict, note))

def denied(fn):
    """Run fn; return True if it raised PermissionError/EPERM, False if it
    succeeded, and re-raise anything else."""
    try:
        fn(); return False
    except PermissionError:
        return True
    except OSError as e:
        if e.errno in (1, 13): return True
        raise

def read_one(p):
    def f():
        fd = os.open(str(p), os.O_RDONLY)
        try: os.read(fd, 1)
        finally: os.close(fd)
    return denied(f)

def create_probe(dirpath, name):
    """Try to create a new file in dirpath (a write). Clean up if it lands."""
    target = pathlib.Path(dirpath) / name
    def f():
        fd = os.open(str(target), os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o600)
        os.close(fd)
    try:
        d = denied(f)
    finally:
        try: target.unlink()
        except OSError: pass
    return d

# ---- control: a non-protected file must work normally ----
ctrl = pathlib.Path(tempfile.mkdtemp()) / "notes.txt"
ok = True
try:
    ctrl.write_text("hello"); assert ctrl.read_text() == "hello"; ctrl.unlink()
except OSError:
    ok = False
record("non-protected file: create/read/delete", False, not ok, "filesystem",
       "legitimate ops must keep working")

# ---- reads of real protected files, several vectors ----
if (SSH / "config").exists():
    record("read ssh config — direct", True, read_one(SSH / "config"), "OS (Endpoint Security)")
    # symlink
    link = pathlib.Path(tempfile.mkdtemp()) / "alias"
    link.symlink_to(SSH / "config")
    record("read ssh config — via symlink", True, read_one(link), "OS (Endpoint Security)")
    # child process
    r = subprocess.run(["/bin/cat", str(SSH / "config")], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    record("read ssh config — child process (cat)", True, r.returncode != 0, "OS (Endpoint Security)",
           "exit %d" % r.returncode)
    # detached via launchd (known gap: re-parented away from the agent)
    out = pathlib.Path(tempfile.mkdtemp()) / "o"
    subprocess.run(["launchctl", "submit", "-l", "kai.breadth.read", "-o", str(out), "-e", str(out),
                    "--", "/bin/cat", str(SSH / "config")], capture_output=True)
    time.sleep(3)
    subprocess.run(["launchctl", "remove", "kai.breadth.read"], capture_output=True)
    got = out.read_text() if out.exists() else ""
    record("read ssh config — detached (launchd)", True, "Operation not permitted" in got or got == "",
           "OS (Endpoint Security)", "launchd reparents away from the agent — expected gap")
else:
    record("read ssh config", True, None, "OS", "~/.ssh/config not present")

# ~/.kai read: strict build (v7) denies; lenient (v6) allows — record actual
if (KAI / "policy").exists():
    record("read kai policy — direct", True, read_one(KAI / "policy"), "OS (Endpoint Security)",
           "strict build should block; lenient allowed")

# ---- write-protection: try to create a new probe file in protected dirs ----
if SSH.exists():
    record("create new file in ~/.ssh (write)", True, create_probe(SSH, "kai_breadth_probe"),
           "OS (Endpoint Security)", "does not touch existing keys")
if KAI.exists():
    record("create new file in ~/.kai (write/tamper)", True, create_probe(KAI, "kai_breadth_probe"),
           "OS (Endpoint Security)")

# disposable protected-pattern files under /tmp (create = a write)
tmpd = tempfile.mkdtemp()
record("create .env under /tmp (write)", True, create_probe(tmpd, "." + "env"), "OS (Endpoint Security)")
record("create .pem under /tmp (write)", True, create_probe(tmpd, "probe." + "pem"), "OS (Endpoint Security)")

# ---- adversarial write-side vectors (no seeding, no real secret touched) ----
def cleanup(path):
    try: os.unlink(path)
    except OSError: pass

# atomic replacement: create a plain temp file, rename it ONTO a protected name
plain = os.path.join(tmpd, "plain.txt"); open(plain, "w").write("x")
dest = os.path.join(tmpd, "." + "env")
d = denied(lambda: os.rename(plain, dest)); cleanup(dest); cleanup(plain)
record("atomic replace: rename plain -> .env (dest protected)", True, d, "OS (Endpoint Security)")

# hard link a REAL secret to an alias (would expose its contents under a new name)
if (SSH / "config").exists():
    alias = os.path.join(tmpd, "hardlink")
    d = denied(lambda: os.link(str(SSH / "config"), alias)); cleanup(alias)
    record("hard link ~/.ssh/config -> alias (source protected)", True, d, "OS (Endpoint Security)")
    # clonefile of a real secret
    clone = os.path.join(tmpd, "clone")
    def do_clone():
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.clonefile(str(SSH / "config").encode(), clone.encode(), 0) != 0:
            raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    d = denied(do_clone); cleanup(clone)
    record("clonefile ~/.ssh/config -> clone (source protected)", True, d, "OS (Endpoint Security)")

# hard link a plain file INTO ~/.ssh (target dir protected -> write/tamper)
if SSH.exists():
    src = os.path.join(tmpd, "linksrc.txt"); open(src, "w").write("x")
    tgt = str(SSH / "kai_breadth_link")
    d = denied(lambda: os.link(src, tgt))
    cleanup(tgt); cleanup(src)
    record("hard link plain -> ~/.ssh/ (target protected)", True, d, "OS (Endpoint Security)")

# inherited file descriptor: ES authorizes open(), not read() on an already-open
# fd, and a non-agent opener is needed to demonstrate it — can't be built from a
# single agent session. Documented limitation.
record("inherited fd (open in non-agent, read in agent)", True, None, "OS — not expressible via ES",
       "ES has no event for reading an already-open fd; needs a non-agent opener")

# directory enumeration of a protected dir (AUTH_READDIR + AUTH_OPEN of the dir)
if SSH.exists():
    def list_ssh():
        import os as _os
        fd = _os.open(str(SSH), _os.O_RDONLY | _os.O_DIRECTORY)
        try: _os.listdir(fd)
        finally: _os.close(fd)
    record("enumerate ~/.ssh directory (readdir)", True, denied(list_ssh), "OS (Endpoint Security)",
           "AUTH_READDIR + AUTH_OPEN of the dir")

# ---- exec-transition / attribution race family (point 7) ----
import subprocess as _sp
def _py(code):
    r = _sp.run(["python3", "-c", code], capture_output=True, text=True)
    return (r.stdout + r.stderr)

ssh_cfg = str(SSH / "config") if (SSH / "config").exists() else ""
if ssh_cfg:
    # child exec then read: a freshly exec'd child of this agent reads a secret
    out = _py("import os,sys\n"
              "try:\n fd=os.open(%r,os.O_RDONLY); os.read(fd,1); os.close(fd); print('OPENED')\n"
              "except OSError as e: print('DENIED',e.errno)" % ssh_cfg)
    record("child exec then read secret", True, "DENIED" in out, "OS (Endpoint Security)", out.strip()[:40])

    # rapid read immediately on process start (minimal time for classification)
    out = _py("import os\n"
              "try:\n open(%r,'rb').read(1); print('OPENED')\n"
              "except OSError as e: print('DENIED',e.errno)" % ssh_cfg)
    record("rapid post-exec read (classification race)", True, "DENIED" in out, "OS (Endpoint Security)",
           "first op of a brand-new pid")

    # same-pid re-exec: python execs cat, which reads the secret (identity kept pid)
    out = _py("import os\n"
              "os.execv('/bin/cat',['cat',%r])" % ssh_cfg)
    record("same-pid re-exec (execv cat secret)", True, "Operation not permitted" in out or out.strip() == "",
           "OS (Endpoint Security)", "exec-transition; empty/EPERM = blocked")

# process-mute invalidation on exec is only meaningful with filter=process; this
# harness records it NOT TESTED under optimization=none and is rerun per mode.
record("process-mute invalidation on re-exec", True, None, "OS (Endpoint Security)",
       "only under filter=process; rerun this harness with ~/.kai/storage_filter=process")

# append/truncate/rename/delete need a pre-existing protected file, which the
# agent can't create (create is blocked). Seeding needs storage off.
for op in ("append", "truncate", "rename", "delete"):
    record("%s a protected file" % op, True, None, "OS (Endpoint Security)",
           "needs a pre-seeded protected file; blocked create prevents agent setup")

# ---- print matrix ----
w = max(len(r[0]) for r in rows)
print("%-*s  %-8s  %-9s  %-24s  %-9s  %s" % (w, "scenario", "expected", "actual", "mechanism", "verdict", "note"))
print("-" * (w + 70))
for s, exp, act, mech, verd, note in rows:
    print("%-*s  %-8s  %-9s  %-24s  %-9s  %s" % (w, s, exp, act, mech, verd, note))
fails = [r for r in rows if r[4] == "FAIL"]
print("\n%d scenarios, %d PASS, %d FAIL, %d NOT TESTED" %
      (len(rows), sum(r[4] == "PASS" for r in rows), len(fails), sum(r[4] == "NOT TESTED" for r in rows)))
