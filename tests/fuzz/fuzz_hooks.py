# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Throw random, malformed input at the hook handler (`make fuzz`).

usage: fuzz_hooks.py <kai> [iterations]

Builds shell commands and tool results out of the characters that matter to
Kai's parsers (quotes, escapes, $(, backticks, heredocs, HTML comments,
invisible characters, multi-byte UTF-8) and checks that every run exits 0
and prints either nothing or valid JSON. Build with `make asan` first so
memory errors abort the run.
"""
import json
import os
import random
import subprocess
import sys
import tempfile

kai = os.path.abspath(sys.argv[1])
n = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
rng = random.Random(1234)
PIECES = ["'", '"', "\\", "$(", ")", "`", "<<", "<<-", "EOF", "\n", ";", "|", "&&", "(", "{", "}",
          " ", "kai", "uninstall", "policy", "set", "~/.ssh", "id_rsa", ".env", "sh -c", "eval",
          "sudo", "xargs", "<!--", "-->", "ignore all previous instructions", "send", ".ssh to",
          "​", "é", "\U0001F600", "#", "=", "k=kai", "$k", "/", "~", "*", "\t", "\r",
          "`kai init`", "python3 -c", "open('", "')"]
env = dict(os.environ, KAI_HOME=tempfile.mkdtemp(), HOME=tempfile.mkdtemp())
bad = 0
for i in range(n):
    text = "".join(rng.choice(PIECES) for _ in range(rng.randint(1, 60)))
    if i % 2 == 0:
        ev = {"hook_event_name": "PreToolUse", "cwd": "/tmp", "tool_name": "Bash",
              "tool_input": {"command": text}}
    else:
        ev = {"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": {"content": text}}
    agent = "codex" if i % 3 == 0 else "claude"
    p = subprocess.run([kai, "hook", agent], input=json.dumps(ev).encode(), capture_output=True,
                       env=env, timeout=20)
    out = p.stdout.decode("utf-8", "strict").strip()
    ok = p.returncode == 0
    if ok and out:
        try:
            json.loads(out)
        except ValueError:
            ok = False
    if not ok:
        bad += 1
        print("FAIL rc=%d input=%r\nstdout=%r\nstderr=%s" % (p.returncode, text, out[:300],
                                                             p.stderr.decode(errors="replace")[:800]))
        if bad > 5:
            break
print("fuzz: %d runs, %d failures" % (i + 1, bad))
sys.exit(1 if bad else 0)
