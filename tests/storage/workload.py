# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Real-workload storage-wall impact (manual). NOT part of `make test`.

Runs representative developer workloads from an agent session and reports
wall-clock time, so the storage wall's overhead can be judged against work
people actually do (not just micro-ops). Run ON (extension active) and OFF
(Storage wall deactivated) and compare. Everything happens in a throwaway temp
dir on non-protected paths — it measures the common case the wall must not
slow down.
"""
import os, shutil, subprocess, tempfile, time

root = tempfile.mkdtemp()

def run(label, fn):
    t0 = time.perf_counter()
    fn()
    dt = time.perf_counter() - t0
    print(f"  {label:34} {dt*1000:8.1f} ms")
    return dt

def git_workload():
    d = os.path.join(root, "repo"); os.makedirs(d)
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    subprocess.run(["git", "init", "-q"], cwd=d, env=env)
    for i in range(500):
        open(os.path.join(d, f"f{i}.txt"), "w").write(f"line {i}\n" * 20)
    subprocess.run(["git", "add", "-A"], cwd=d, env=env)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"], cwd=d, env=env)
    for _ in range(10):
        subprocess.run(["git", "status", "--porcelain"], cwd=d, env=env, stdout=subprocess.DEVNULL)

def compile_workload():
    d = os.path.join(root, "cc"); os.makedirs(d)
    src = os.path.join(d, "m.c")
    open(src, "w").write("#include <stdio.h>\nint main(void){printf(\"hi\");return 0;}\n")
    for i in range(30):
        subprocess.run(["cc", "-O2", "-o", os.path.join(d, f"a{i}.out"), src],
                       stderr=subprocess.DEVNULL)

def package_churn():
    # thousands of small files in nested dirs, like node_modules / pip install
    base = os.path.join(root, "pkgs")
    for p in range(40):
        pk = os.path.join(base, f"pkg{p}", "dist")
        os.makedirs(pk)
        for i in range(50):
            open(os.path.join(pk, f"m{i}.js"), "w").write("export const x = %d;\n" % i)

def create_delete():
    d = os.path.join(root, "cd"); os.makedirs(d)
    for i in range(3000):
        p = os.path.join(d, f"t{i}"); open(p, "w").write("x"); os.unlink(p)

print("real-workload impact  (wall-clock; run ON vs OFF and compare)")
run("git: init + 500 files + commit + status", git_workload)
run("compile: 30x cc -O2", compile_workload)
run("package churn: 2000 small files", package_churn)
run("create+delete 3000 files", create_delete)
shutil.rmtree(root, ignore_errors=True)
