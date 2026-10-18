# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Live check of the macOS network wall. Not part of `make test`.

usage: python3 tests/network/run_network_check.py [kai]

The wall filters only connections from AI agents, so run this from your
agent's terminal tool (for example, ask Claude Code to run it), with the
network extension enabled and `egress block`. It makes harmless requests to
public test hosts (example.com, example.org, example.net, portquiz.net,
github.com, a DNS lookup) and writes tests/network/results.json, which
`make validation` puts into docs/SECURITY-VALIDATION.md.

An attempt counts as blocked only if it failed AND Kai's log has a block for
that host; a failure Kai didn't log is reported as "failed (not Kai)", so a
flaky network can't pass for a working wall. The wall logs each agent+host
once per 10 minutes, so a block logged in the 10 minutes before the run also
counts; "logged" says whether this run's attempt got its own record. For a
clean run, wait 10 minutes after the last one.
"""
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

here = os.path.dirname(os.path.abspath(__file__))
kai = sys.argv[1] if len(sys.argv) > 1 else (shutil.which("kai") or os.path.join(here, "..", "..", "kai"))
TIMEOUT = "8"


def curl(*args):
    r = subprocess.run(["curl", "-sS", "-m", TIMEOUT, "-o", "/dev/null", "-w", "%{http_code}", *args],
                       capture_output=True, text=True)
    return r.stdout.strip() not in ("", "000")


def python_post():
    import urllib.request
    try:
        urllib.request.urlopen("https://example.com/", data=b"KAI-FAKE-NOTES", timeout=8)
        return True
    except urllib.error.HTTPError:
        return True  # the server answered, so the data left
    except Exception:
        return False


def raw_socket(ip, port):
    """Plain TCP to an IP: no hostname anywhere. On ports other than 80/443 the
    wall decides when the connection opens. The target is 192.0.2.1 (TEST-NET,
    reserved for documentation): nothing answers there and no name resolves
    to it, so macOS can't attach a host name. A dropped connection fails at
    once; one the wall lets out just times out (its packets did leave)."""
    try:
        with socket.create_connection((ip, port), timeout=4):
            return True
    except socket.timeout:
        return True
    except OSError:
        return False


def dns():
    r = subprocess.run(["dig", "+short", "+time=3", "+tries=1", "example.com", "@1.1.1.1", "A"],
                       capture_output=True, text=True)
    return r.returncode == 0 and bool(r.stdout.strip())


def nohup_child(scratch, host, orphan):
    """Background a request. With orphan, the shell that started it exits at
    once, so the request's parent becomes launchd while it runs."""
    out = os.path.join(scratch, host + ".out")
    wait = "" if orphan else " wait"
    subprocess.run(["/bin/sh", "-c", f'nohup curl -sS -m {TIMEOUT} -o /dev/null -w "%{{http_code}}" '
                    f'https://{host}/ > "{out}" 2>/dev/null &' + wait])
    if orphan:
        time.sleep(int(TIMEOUT) + 2)
    code = open(out).read().strip() if os.path.exists(out) else ""
    return code not in ("", "000")


def launchd_child(scratch):
    """Hand the request to launchd, so it's no longer the agent's child."""
    out = os.path.join(scratch, "launchd.out")
    label = "io.github.sameehj.kai.netcheck"
    subprocess.run(["launchctl", "remove", label], capture_output=True)
    subprocess.run(["launchctl", "submit", "-l", label, "-o", out, "-e", out, "--", "/usr/bin/curl", "-sS",
                    "-m", TIMEOUT, "-o", "/dev/null", "-w", "%{http_code}", "https://example.org/"],
                   capture_output=True)
    time.sleep(int(TIMEOUT) + 2)
    subprocess.run(["launchctl", "remove", label], capture_output=True)
    code = open(out).read().strip() if os.path.exists(out) else ""
    return code.endswith("200") or (code[-3:].isdigit() and code[-3:] != "000")


def records_since(start):
    """Network records (blocked or only noticed) at or after start (ISO UTC)."""
    r = subprocess.run([kai, "log", "tail"], capture_output=True, text=True)
    seen = []
    for line in r.stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("source") == "network" and e.get("ts", "") >= start:
            seen.append(e)
    return seen


def main():
    if sys.platform != "darwin":
        sys.exit("the network wall is macOS only")
    scratch = os.path.join(here, ".run")
    shutil.rmtree(scratch, ignore_errors=True)
    os.makedirs(scratch)
    now = datetime.now(timezone.utc)
    start = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    window = datetime.fromtimestamp(now.timestamp() - 600, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ip = "1.0.0.1"  # Cloudflare's resolver also serves HTTPS; never looked up by name here
    # The no-name tests go first.
    tests = [
        ("raw-ip-port", "Raw TCP to an IP on another port (no hostname; 192.0.2.1:22)", "192.0.2.1:22",
         lambda: raw_socket("192.0.2.1", 22), "blocked"),
        ("https-ip", "HTTPS straight to an IP address, no hostname", ip or "?",
         lambda: curl("-k", f"https://{ip}/"), "blocked"),
        ("https-unknown", "HTTPS to a host that isn't allowed (example.com)", "example.com",
         lambda: curl("https://example.com/"), "blocked"),
        ("http-80", "Plain HTTP on port 80", "example.com", lambda: curl("http://example.com/"), "blocked"),
        ("other-port", "HTTP on another port (portquiz.net:8080)", "portquiz.net",
         lambda: curl("http://portquiz.net:8080/"), "blocked"),
        ("python-post", "POST data from Python", "example.com", python_post, "blocked"),
        ("nohup", "Backgrounded request while its parent keeps running (nohup … &)", "example.net",
         lambda: nohup_child(scratch, "example.net", False), "blocked"),
        ("nohup-orphan", "Backgrounded request whose parent shell exits at once", "www.example.com",
         lambda: nohup_child(scratch, "www.example.com", True), "blocked"),
        ("launchd", "Request handed to launchd (no longer the agent's child)", "example.org",
         lambda: launchd_child(scratch), "blocked"),
        ("dns", "DNS lookup to a public resolver (udp/53)", None, dns, "blocked"),
        ("allowed", "HTTPS to an allowed host (github.com)", "github.com",
         lambda: curl("https://github.com/"), "allowed"),
    ]
    raw = []
    for tid, attempt, host, fn, expected in tests:
        ok = fn()
        raw.append((tid, attempt, host, ok, expected))
        print(f"  {'connected' if ok else 'failed   '}  {attempt}")
    time.sleep(2)
    recent = records_since(window)
    logged = [e for e in recent if e.get("ts", "") >= start]
    label = {"claude": "Claude Code", "cursor": "Cursor", "codex": "Codex"}
    results = []
    agents_seen = set()
    for tid, attempt, host, ok, expected in raw:
        def names(e):
            r = e.get("rule", "")
            return bool(host) and (r == host or r.startswith(host + ":") or r == host.split(":")[0]
                                   or e.get("detail", "").startswith(f"connection to {host} "))
        was_logged = any(names(e) for e in logged)
        if ok:
            result = "got through"
        elif any(names(e) and e.get("decision") == "block" for e in recent):
            result = "blocked"
        else:
            result = "failed (not Kai)"
        for e in recent:
            if names(e) and e.get("event"):
                agents_seen.add(label.get(e["event"], e["event"]))
        results.append({"id": tid, "attempt": attempt, "result": result, "logged": was_logged,
                        "expected": expected})
    policy = subprocess.run([kai, "policy", "show", "--json"], capture_output=True, text=True).stdout
    try:
        egress = json.loads(policy)["switches"]["egress"]
    except (ValueError, KeyError):
        egress = "unknown"
    out = {
        "run_at": start,
        "os": "macOS " + subprocess.run(["sw_vers", "-productVersion"], capture_output=True,
                                        text=True).stdout.strip() + f" ({platform.machine()})",
        "egress": egress,
        "agent": ", ".join(sorted(agents_seen)) or "an unrecognized process (nothing was attributed to an agent)",
        "results": results,
    }
    with open(os.path.join(here, "results.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    shutil.rmtree(scratch, ignore_errors=True)
    print("\nwrote tests/network/results.json")
    for r in results:
        print(f"  {r['result']:17} logged={'yes' if r['logged'] else 'no ':3}  {r['attempt']}")


main()
