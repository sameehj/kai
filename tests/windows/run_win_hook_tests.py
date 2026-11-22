# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Windows end-to-end tests for kai.exe: each agent's hook event, in that
agent's format, sent to the real `kai hook`, plus install / doctor / uninstall
from a folder with a space in its name. Throwaway USERPROFILE and KAI_HOME
only; fake secrets only; nothing is printed from any file.

usage: python -I tests/windows/run_win_hook_tests.py <path to kai.exe>
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile

if sys.platform != "win32":
    print("Windows only: skipped")
    sys.exit(0)

KAI = os.path.abspath(sys.argv[1])
B = "\\"
fails = checks = 0


def check(ok, what):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
        print("  FAIL:", what)


root = os.path.realpath(tempfile.mkdtemp(prefix="kai win "))   # a space in every path below
home = os.path.join(root, "First Last")
proj = os.path.join(home, "proj")
for d in (".ssh", ".aws", "proj", "scratch", "AppData\\Roaming", "AppData\\Local",
          ".claude", ".codex", ".cursor"):   # agents kai install all detects
    os.makedirs(os.path.join(home, d), exist_ok=True)
for rel, text in {".ssh\\id_ed25519": "KAI-FAKE-SSH-KEY\n", "proj\\.env": "KAI_FAKE=1\n",
                  "proj\\notes.txt": "notes\n", "proj\\main.c": "int main(void){return 0;}\n"}.items():
    with open(os.path.join(home, rel), "w") as f:
        f.write(text)
env = dict(os.environ, USERPROFILE=home, HOME=home, KAI_HOME=os.path.join(root, "kai-home"),
           APPDATA=os.path.join(home, "AppData", "Roaming"), LOCALAPPDATA=os.path.join(home, "AppData", "Local"))
env.pop("KAI_POLICY", None)
key = os.path.join(home, ".ssh", "id_ed25519")


def hook(agent, event, raw_prefix=b""):
    data = raw_prefix + json.dumps(event).encode("utf-8")
    r = subprocess.run([KAI, "hook", agent], input=data, capture_output=True, env=env, timeout=30)
    return r.returncode, r.stdout.decode("utf-8", "replace")


def stopped(out):
    o = out.replace(" ", "")
    return ('"permissionDecision":"deny"' in o or '"permissionDecision":"ask"' in o
            or '"permission":"deny"' in o or '"permission":"ask"' in o or '"decision":"block"' in o)


def claude(tool, ti):
    return {"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": ti, "cwd": proj}


def codex(ti, tool="shell"):
    return {"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": ti, "cwd": proj,
            "turn_id": "t", "model": "m", "permission_mode": "default"}


def cursor_shell(cmd):
    return {"hook_event_name": "beforeShellExecution", "command": cmd, "cwd": proj,
            "conversation_id": "c", "generation_id": "g", "workspace_roots": [proj]}


def cursor_read(path):
    return {"hook_event_name": "beforeReadFile", "file_path": path, "content": "", "conversation_id": "c",
            "generation_id": "g", "workspace_roots": [proj]}


print("== Windows hook tests ==")

print("reads of a protected file, every agent")
for path in (key, key.upper(), key.replace(B, "/"), B + B + "?" + B + key, key + ":stream",
             os.path.join(proj, ".env::$DATA"), os.path.join(proj, ".env.")):
    check(stopped(hook("claude", claude("Read", {"file_path": path}))[1]), "claude Read " + path)
    check(stopped(hook("cursor", cursor_read(path))[1]), "cursor beforeReadFile " + path)

print("shell reads: Claude Code PowerShell and Bash tools, Codex, Cursor")
reads = ["Get-Content $env:USERPROFILE" + B + ".ssh" + B + "id_ed25519",
         "type %USERPROFILE%" + B + ".ssh" + B + "id_ed25519",
         "cmd /c type .env", "Select-String -Path .env -Pattern KAI",
         "powershell -enc " + base64.b64encode(b"g\0c\0 \0.\0e\0n\0v\0").decode()]
for c in reads:
    check(stopped(hook("claude", claude("PowerShell", {"command": c}))[1]), "claude PowerShell: " + c)
    check(stopped(hook("codex", codex({"command": c}))[1]), "codex string: " + c)
    check(stopped(hook("codex", codex({"command": ["powershell.exe", "-Command", c]}))[1]), "codex argv: " + c)
    check(stopped(hook("cursor", cursor_shell(c))[1]), "cursor: " + c)
check(stopped(hook("claude", claude("Bash", {"command": "cat ~/.ssh/id_ed25519"}))[1]), "claude Bash (Git Bash)")
check(stopped(hook("claude", claude("Bash", {"command": "cat /c" + home[2:].replace(B, "/") + "/.ssh/id_ed25519"}))[1]),
      "claude Bash with a /c/... path")

print("Cursor's UTF-8 BOM on stdin")
check(stopped(hook("cursor", cursor_shell("type .env"), raw_prefix=b"\xef\xbb\xbf")[1]), "BOM + protected read")
rc, out = hook("cursor", cursor_shell("git status"), raw_prefix=b"\xef\xbb\xbf")
check(rc == 0 and not stopped(out), "BOM + normal command allowed")

print("destructive commands")
for c in ("Remove-Item -Recurse -Force " + os.path.join(home, "scratch"), "rd /s /q scratch", "del /s /q *.log"):
    check(stopped(hook("claude", claude("PowerShell", {"command": c}))[1]), "claude: " + c)
    check(stopped(hook("codex", codex({"command": c}))[1]), "codex: " + c)
    check(stopped(hook("cursor", cursor_shell(c))[1]), "cursor: " + c)
out = hook("codex", codex({"command": "Remove-Item -Recurse -Force scratch"}))[1]
check('"deny"' in out, "codex gets deny, not ask (Codex can't ask)")

print("normal work goes through quietly")
for c in ("git status", "npm test", "Get-ChildItem -Recurse src", "dotnet build", "python -m pytest",
          "Remove-Item build" + B + "out.txt", "Copy-Item main.c main2.c", "rm -rf build"):
    for agent, ev in (("claude", claude("PowerShell", {"command": c})), ("codex", codex({"command": c})),
                      ("cursor", cursor_shell(c))):
        rc, out = hook(agent, ev)
        check(rc == 0 and not stopped(out), agent + " allows: " + c)
rc, out = hook("claude", claude("Edit", {"file_path": os.path.join(proj, "main.c"), "old_string": "0", "new_string": "1"}))
check(rc == 0 and not stopped(out), "claude Edit of a project file")
rc, out = hook("claude", claude("Read", {"file_path": os.path.join(proj, "main.c")}))
check(rc == 0 and not stopped(out), "claude Read of a project file")

print("kai install / doctor / uninstall from a folder with a space")
inst = os.path.join(home, "Kai Programs")
os.makedirs(inst)
exe = os.path.join(inst, "kai.exe")
shutil.copy(KAI, exe)
ie = dict(env, KAI_TEST_ALLOW_DEV_HOOK="1")   # a temp folder may sit inside a git checkout
r = subprocess.run([exe, "install", "all"], capture_output=True, text=True, encoding="utf-8", env=ie, timeout=60)
check(r.returncode == 0, "install all: rc " + str(r.returncode))
cs = json.load(open(os.path.join(home, ".claude", "settings.json")))
entries = [h for g in cs["hooks"]["PreToolUse"] for h in g["hooks"]]
check(any(h.get("command") == exe.replace(B, "/") and h.get("args") == ["hook", "claude"] for h in entries),
      "Claude Code: exec form (command + args)")
check(any("PowerShell" in g.get("matcher", "").split("|") for g in cs["hooks"]["PreToolUse"]),
      "Claude Code: the PowerShell tool is matched")
for agent, rel in (("codex", ".codex\\hooks.json"), ("cursor", ".cursor\\hooks.json")):
    txt = open(os.path.join(home, rel)).read()
    check(("hook " + agent) in txt, agent + " hook command written")
    cmd = json.loads(txt)
    cmds = [h["command"] for v in cmd["hooks"].values() for g in v for h in (g.get("hooks") or [g])]
    check(all(" " not in c.split(" hook ")[0] or c.startswith("& '") for c in cmds),
          agent + ": path is bare (8.3) or PowerShell-quoted")
r = subprocess.run([exe, "doctor"], capture_output=True, text=True, encoding="utf-8", env=ie, timeout=120)
for name in ("Claude Code", "Codex", "Cursor"):
    check(any(line.startswith("✓ " + name) and "denied as expected" in line for line in r.stdout.splitlines()),
          "doctor: " + name + " hook answers its probe")
st = json.loads(subprocess.run([exe, "status", "--json"], capture_output=True, text=True, encoding="utf-8", env=ie, timeout=120).stdout)
check(st.get("state") == "ok", "status --json state ok: " + json.dumps(st.get("degraded")))
check(st["claude"]["installed"] and st["codex"]["installed"] and st["cursor"]["installed"], "status: all installed")
r = subprocess.run([exe, "uninstall", "all"], capture_output=True, text=True, encoding="utf-8", env=ie, timeout=60)
check(r.returncode == 0, "uninstall all")
for rel in (".claude\\settings.json", ".codex\\hooks.json", ".cursor\\hooks.json"):
    p = os.path.join(home, rel)
    check(not os.path.exists(p) or "hook " not in open(p).read(), "uninstalled from " + rel)

print("protected Windows stores")
for p in (os.path.join(env["LOCALAPPDATA"], "Google", "Chrome", "User Data", "Default", "Login Data"),
          os.path.join(env["APPDATA"], "Microsoft", "Windows", "PowerShell", "PSReadLine", "ConsoleHost_history.txt"),
          os.path.join(home, ".azure", "msal_token_cache.json"), os.path.join(home, ".git-credentials")):
    check(stopped(hook("claude", claude("Read", {"file_path": p}))[1]), "protected: " + p)

shutil.rmtree(root, ignore_errors=True)
print(f"\n{checks} checks, {fails} failures")
sys.exit(1 if fails else 0)
