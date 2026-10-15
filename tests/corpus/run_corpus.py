# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Measure Kai's prompt-injection warnings against labelled text.

usage: run_corpus.py <kai>

Each file is handed to `kai hook claude` as a tool result (PostToolUse), the
way an agent would see it after reading a page, file or tool output:

  tests/corpus/attack/*   must produce a warning   (a miss is a failure)
  tests/corpus/benign/*   must not                 (a false alarm is a failure)
  + Kai's own README, docs and policy, which talk about attacks a lot and
    are exactly what tripped the old keyword check.

Prints one line per file and the totals; exits 1 on any mistake.
"""
import json
import os
import subprocess
import sys
import tempfile

kai = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.dirname(os.path.dirname(here))

cases = []
for label in ("attack", "benign"):
    d = os.path.join(here, label)
    for name in sorted(os.listdir(d)):
        cases.append((label, os.path.join(d, name)))
for rel in ("README.md", "docs/THREAT_MODEL.md", "docs/WALLS.md", "docs/DESIGN.md",
            "policy/default.policy", "CHANGELOG.md", "integrations/README.md", "SECURITY.md",
            "tests/hooks/run_hook_tests.sh", "src/scan.c"):
    path = os.path.join(repo, rel)
    if os.path.exists(path):
        cases.append(("benign", path))

env = dict(os.environ, KAI_HOME=tempfile.mkdtemp(), HOME=tempfile.mkdtemp())
env.pop("KAI_POLICY", None)
mistakes = 0
counts = {"attack": [0, 0], "benign": [0, 0]}  # [flagged, total]
for label, path in cases:
    text = open(path, encoding="utf-8", errors="replace").read()
    event = {"hook_event_name": "PostToolUse", "tool_name": "Read",
             "tool_input": {"file_path": path}, "tool_response": {"content": text}}
    out = subprocess.run([kai, "hook", "claude"], input=json.dumps(event), capture_output=True,
                         text=True, env=env, timeout=30).stdout
    flagged = "Kai warning" in out
    counts[label][0] += flagged
    counts[label][1] += 1
    ok = flagged if label == "attack" else not flagged
    mistakes += not ok
    why = ""
    if flagged:
        ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
        why = ctx[ctx.find("("):ctx.find(")") + 1]
    print(f"  {'ok  ' if ok else 'FAIL'} {label:6} {'warned ' + why if flagged else 'quiet':30} "
          f"{os.path.relpath(path, repo)}")

a, b = counts["attack"], counts["benign"]
print(f"\nattacks caught: {a[0]}/{a[1]}   false alarms: {b[0]}/{b[1]}")
print("corpus: all passed" if mistakes == 0 else f"corpus: {mistakes} mistakes")
sys.exit(1 if mistakes else 0)
