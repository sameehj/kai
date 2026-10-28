#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# CLI tests: status, policy editing and install/uninstall, all inside a
# throwaway HOME so nothing on the machine is touched.
set -u
KAI="$(cd "$(dirname "${1:-./kai}")" && pwd)/$(basename "${1:-./kai}")"
TMP="$(mktemp -d)"
export HOME="$TMP" KAI_HOME="$TMP/.kai"
unset KAI_POLICY
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
# has(name, haystack, needle)
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (got: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1 (unexpected: $2)" ;; *) pass "$1" ;; esac; }
count() { printf '%s' "$1" | grep -c "$2"; }

echo "== status =="
out=$("$KAI" status --json)
has "status is json with version" "$out" '"version"'
has "status: built-in policy before init" "$out" '"source":	"built-in"'
has "status: claude not installed" "$out" '"installed":	false'

echo "== status (measured, A2) =="
st=$("$KAI" status)
has "status: agent checks section" "$st" "Agent checks"
has "status: an unused agent is not claimed active" "$st" "Not detected"
has "status: OS protection line" "$st" "OS protection"
has "status: coverage line" "$st" "Coverage"
hasnt "status: no agent reported Active in an empty home" "$st" "Active ("
has "status: points to kai doctor" "$st" "kai doctor"
dr=$("$KAI" doctor 2>&1)
has "doctor: checks the policy" "$dr" "policy loads"
has "doctor: says what it couldn't measure" "$dr" "not measured"

echo "== policy set =="
"$KAI" policy set on_upload ask >/dev/null
has "set creates the policy file" "$(ls "$KAI_HOME")" "policy"
has "set changes the switch" "$("$KAI" policy show --json)" '"on_upload":	"ask"'
"$KAI" policy set on_upload block >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" '^on_upload')" = 1 ] && pass "set replaces in place" || fail "set duplicated the line"
"$KAI" policy set on_upload maybe >/dev/null 2>&1 && fail "bad value accepted" || pass "bad value rejected"
"$KAI" policy set nonsense 1 >/dev/null 2>&1 && fail "unknown switch accepted" || pass "unknown switch rejected"

echo "== protect / allow =="
"$KAI" policy add protect ~/secret-stuff >/dev/null
has "add protect" "$("$KAI" policy show --json)" 'secret-stuff'
"$KAI" policy add protect ~/secret-stuff >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" 'secret-stuff')" = 1 ] && pass "add protect is idempotent" || fail "add protect duplicated"
"$KAI" policy remove protect ~/secret-stuff >/dev/null
hasnt "remove protect" "$(cat "$KAI_HOME/policy")" 'secret-stuff'
"$KAI" policy remove protect ~/never-there >/dev/null 2>&1 && fail "removing missing entry succeeded" || pass "removing missing entry fails"

echo "== terms and rules =="
"$KAI" policy add term 'replace:"Project X"' Project Falcon >/dev/null
has "term shows in json" "$("$KAI" policy show --json)" '"replacement":	"Project X"'
has "term is enforced" "$(printf 'about Project Falcon' | "$KAI" redact)" 'Project X'
"$KAI" policy add term block Project Falcon >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" 'Project Falcon')" = 1 ] && pass "re-adding a term updates it" || fail "term duplicated"
"$KAI" policy remove term Project Falcon >/dev/null
hasnt "remove term" "$(cat "$KAI_HOME/policy")" 'Project Falcon'
"$KAI" policy add rule bad_rule block '([unclosed' >/dev/null 2>&1 && fail "invalid regex accepted" || pass "invalid regex rejected"
hasnt "rejected change not written" "$(cat "$KAI_HOME/policy")" 'bad_rule'
"$KAI" policy add rule corp_host redact 'internal-[a-z]+[.]corp' >/dev/null
has "rule is enforced" "$(printf 'host internal-db.corp ok' | "$KAI" redact)" 'REDACTED'
"$KAI" policy remove rule corp_host >/dev/null
hasnt "remove rule" "$(cat "$KAI_HOME/policy")" 'corp_host'

echo "== other agents =="
"$KAI" policy add agent aider arg '*/bin/aider' >/dev/null
"$KAI" policy add agent aider arg '*/bin/aider' >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" '^agent aider')" = 1 ] && pass "add agent is idempotent" || fail "agent duplicated"
"$KAI" policy add agent aider team ABCDE12345 >/dev/null
has "agents listed in json" "$("$KAI" policy show --json)" '"kind":	"team"'
"$KAI" policy add agent aider sideways x >/dev/null 2>&1 && fail "bad agent kind accepted" || pass "bad agent kind rejected"
"$KAI" policy add agent 'bad name' exe x >/dev/null 2>&1 && fail "bad agent name accepted" || pass "bad agent name rejected"
"$KAI" policy remove agent aider >/dev/null
hasnt "remove agent drops all its lines" "$(cat "$KAI_HOME/policy")" 'agent aider'

echo "== allowed destinations =="
for d in artifacts.example.com '*.corp.example.com' db.example.com:5432 10.0.0.0/8 203.0.113.5:22 '[2001:db8::1]:22'; do
    "$KAI" policy add egress_allow "$d" >/dev/null 2>&1 && pass "egress_allow $d accepted" || fail "egress_allow $d rejected"
done
for d in 10.0.0.0/33 1.2.3.4:99999 'host/8' '[1.2.3.4]:22' 'a;b'; do
    "$KAI" policy add egress_allow "$d" >/dev/null 2>&1 && fail "egress_allow $d accepted" || pass "egress_allow $d rejected"
done
has "address entries listed in json" "$("$KAI" policy show --json)" '"203.0.113.5:22"'
"$KAI" policy remove egress_allow 203.0.113.5:22 >/dev/null
hasnt "remove egress_allow" "$(cat "$KAI_HOME/policy")" '203.0.113.5:22'

echo "== exceptions =="
"$KAI" policy add exempt netcat 'python3 tests/*' >/dev/null
has "add exempt" "$("$KAI" policy show --json)" '"pattern":	"python3 tests/*"'
"$KAI" policy add exempt netcat 'python3 tests/*' >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" '^exempt')" = 1 ] && pass "add exempt is idempotent" || fail "add exempt duplicated"
"$KAI" policy add exempt kai_self_protect '*' >/dev/null 2>&1 && fail "self-protection exempted" || pass "self-protection can't be exempted"
"$KAI" policy add exempt '~/.kai' '*' >/dev/null 2>&1 && fail "kai home exempted" || pass "Kai's files can't be exempted"
"$KAI" policy add exempt netcat 'a # b' >/dev/null 2>&1 && fail "'#' accepted" || pass "'#' rejected"
"$KAI" policy remove exempt netcat 'python3 tests/*' >/dev/null
hasnt "remove exempt" "$(cat "$KAI_HOME/policy")" 'exempt netcat'
"$KAI" policy set audit_context off >/dev/null
has "audit_context switch" "$("$KAI" policy show --json)" '"audit_context":	"off"'
"$KAI" policy set audit_context on >/dev/null

echo "== audit log =="
ALLOWED='{"hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Read","tool_input":{"file_path":"README.md"}}'
DENIED='{"hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Read","tool_input":{"file_path":"~/.ssh/id_rsa"}}'
before=$(cat "$KAI_HOME/audit.log" 2>/dev/null | wc -l)
for _ in 1 2 3 4 5; do printf '%s' "$ALLOWED" | "$KAI" hook claude >/dev/null; done
after=$(cat "$KAI_HOME/audit.log" 2>/dev/null | wc -l)
[ "$before" = "$after" ] && pass "allowed tool calls are not logged" || fail "allowed calls logged ($before -> $after)"
printf '%s' "$DENIED" | "$KAI" hook claude >/dev/null
has "blocked tool call is logged" "$(tail -n 1 "$KAI_HOME/audit.log")" '"decision":"block"'
# rotation: a tiny limit forces several rotations
export KAI_AUDIT_MAX_BYTES=1500
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '%s' "$DENIED" | "$KAI" hook claude >/dev/null; done
unset KAI_AUDIT_MAX_BYTES
[ -f "$KAI_HOME/audit.log.1" ] && pass "log rotated to audit.log.1" || fail "no rotation"
has "new log starts with a link to the old one" "$(head -n 1 "$KAI_HOME/audit.log")" '"event":"rotate"'
"$KAI" log verify >/dev/null && pass "rotated log verifies" || fail "rotated log broken"
"$KAI" log verify >/dev/null 2>&1
# appending must not slow down as the log grows: time 40 appends on a
# small log, then on one with 20,000 more records (relative, so it holds
# for sanitizer builds too)
now() { python3 -I -c 'import time; print(time.time())'; }
avg40() { t0=$(now); for _ in $(seq 40); do printf '%s' "$DENIED" | "$KAI" hook claude >/dev/null; done; t1=$(now); echo "$t0 $t1"; }
small=$(avg40)
python3 -I - "$KAI_HOME/audit.log" <<'PY'
import sys
with open(sys.argv[1], "a") as f:
    for i in range(20000):
        f.write('{"ts":"x","source":"t","event":"t","decision":"block","rule":"r","detail":"d","prev":"p","h":"%064d"}\n' % i)
PY
big=$(avg40)
python3 -I -c "
import sys
s0,s1=map(float,'$small'.split()); b0,b1=map(float,'$big'.split())
s=(s1-s0)/40; b=(b1-b0)/40
print('  info append: %.1f ms on a small log, %.1f ms with 20,000 more records' % (s*1000, b*1000))
sys.exit(0 if b < s*2 + 0.005 else 1)" \
  && pass "append time doesn't grow with the log" || fail "append slows down as the log grows"
mv "$KAI_HOME/audit.log" "$KAI_HOME/audit.log.junk"

# Run each of Kai's installed hook commands with Kai's program gone. Blocking
# events must exit 2 (the agent then blocks) with a reason; Stop and
# PostToolUse must not (exit 2 on Stop would keep the agent from stopping).
fails_closed() {
    python3 -I - "$1" "$2" "$KAI" <<'PY'
import json, subprocess, sys
path, agent, kai = sys.argv[1:]
d = json.load(open(path))
bad = []
for event, groups in d["hooks"].items():
    for g in groups:
        for h in g.get("hooks", []):
            cmd = h.get("command", "")
            if " hook " + agent not in cmd:
                continue
            gone = cmd.replace(kai, "/nonexistent/kai")
            r = subprocess.run(["/bin/sh", "-c", gone], input="{}", capture_output=True, text=True)
            want = event in ("PreToolUse", "UserPromptSubmit")
            if want and (r.returncode != 2 or "Kai couldn't check this" not in r.stderr):
                bad.append(f"{event}: exit {r.returncode}")
            if not want and r.returncode == 2:
                bad.append(f"{event}: exit 2 would not be harmless")
print("ok" if not bad else "; ".join(bad))
PY
}

# Install/uninstall write agent hook settings. Inside an agent with Files
# protection on, Kai blocks that even in this throwaway HOME: skip these cases
# ("needs a non-agent shell") rather than fail them. CI runs them.
if ! sh "$(dirname "$0")/../hook_writes_ok.sh"; then
    echo "== install / uninstall: skipped - needs a non-agent shell (Files protection blocks agent hook settings) =="
else
echo "== install / uninstall =="
mkdir -p "$HOME/.claude"
printf '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$HOME/.claude/settings.json"
"$KAI" install claude >/dev/null
once=$(count "$(cat "$HOME/.claude/settings.json")" 'hook claude')
"$KAI" install claude >/dev/null
# Idempotence, not a hard-coded count (it was 5 until the SessionStart hook
# made it 6 and this check failed for a stale reason).
[ "$once" -ge 5 ] && [ "$(count "$(cat "$HOME/.claude/settings.json")" 'hook claude')" = "$once" ] \
  && pass "install twice adds hooks once" || fail "install duplicated hooks"
has "install keeps the user's own Stop hook" "$(cat "$HOME/.claude/settings.json")" 'echo mine'
has "status: claude installed" "$("$KAI" status --json)" '"installed":	true'
claude_health() { "$KAI" status --json | python3 -I -c 'import json,sys; c=json.load(sys.stdin)["claude"]; print(c.get("working"), c.get("problem"))'; }
n0=$(wc -l < "$KAI_HOME/audit.log" 2>/dev/null || echo 0)
has "status: claude hook answers a live check" "$(claude_health)" 'True'
n1=$(wc -l < "$KAI_HOME/audit.log" 2>/dev/null || echo 0)
[ "$n0" = "$n1" ] && pass "health probes aren't recorded" || fail "health probes wrote $((n1-n0)) audit records"
# Point the hooks at a copy of kai, then delete it: status must say so.
mkdir -p "$TMP/gone" && cp "$KAI" "$TMP/gone/kai"
"$TMP/gone/kai" install claude >/dev/null
rm "$TMP/gone/kai"
has "status: missing kai program is a problem" "$(claude_health)" "False Kai's program is missing"
has "status: says the agent is blocked meanwhile" "$(claude_health)" 'blocked until Kai is reinstalled'
# An old-style hook (no fail-closed guard) answers but is flagged.
python3 -I - "$HOME/.claude/settings.json" "$KAI" <<'PY'
import json, sys
p, kai = sys.argv[1:]
d = json.load(open(p))
for groups in d["hooks"].values():
    for g in groups:
        for h in g.get("hooks", []):
            if " hook claude" in h.get("command", ""):
                h["command"] = kai + " hook claude"
json.dump(d, open(p, "w"))
PY
has "status: unguarded hooks are flagged" "$(claude_health)" 'older Kai'
"$KAI" install claude >/dev/null
has "status: reinstall fixes it" "$(claude_health)" 'True'
has "claude hooks fail closed when Kai is missing (not on Stop)" "$(fails_closed "$HOME/.claude/settings.json" claude)" 'ok'
"$KAI" uninstall claude >/dev/null
s=$(cat "$HOME/.claude/settings.json")
hasnt "uninstall removes kai hooks" "$s" 'hook claude'
has "uninstall keeps user hooks" "$s" 'echo mine'
has "uninstall keeps other settings" "$s" '"theme"'

echo "== codex install / uninstall =="
export CODEX_HOME="$TMP/codex-home"
codex_installed() { "$KAI" status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["codex"]["installed"])'; }
has "status: codex not installed" "$(codex_installed)" "False"
"$KAI" install all >/dev/null
[ -e "$CODEX_HOME/hooks.json" ] && fail "install all wrote codex hooks without codex present" || pass "install all skips codex when not used here"
mkdir -p "$CODEX_HOME"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine"}]}],"Stop":[{"hooks":[{"type":"command","command":"echo stop"}]}]},"other":1}' > "$CODEX_HOME/hooks.json"
"$KAI" install codex >/dev/null
"$KAI" install codex >/dev/null
s=$(cat "$CODEX_HOME/hooks.json")
[ "$(count "$s" 'hook codex')" = 3 ] && pass "install codex twice adds hooks once" || fail "codex hooks duplicated ($(count "$s" 'hook codex'))"
hasnt "codex entries carry no _kai marker" "$s" '_kai'
has "codex hooks fail closed when Kai is missing" "$(fails_closed "$CODEX_HOME/hooks.json" codex)" 'ok'
has "status: codex installed" "$(codex_installed)" "True"
has "doctor reports codex" "$("$KAI" doctor)" 'Codex: hooks in'
"$KAI" uninstall codex >/dev/null
s=$(cat "$CODEX_HOME/hooks.json")
hasnt "uninstall removes kai codex hooks" "$s" 'hook codex'
has "uninstall keeps user PreToolUse hook" "$s" 'echo mine'
has "uninstall keeps user Stop hook" "$s" 'echo stop'
has "uninstall keeps other keys" "$s" '"other"'
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "PostToolUse" not in d["hooks"] else 1)' "$CODEX_HOME/hooks.json" \
  && pass "uninstall drops events left empty" || fail "empty codex event left behind"
unset CODEX_HOME
fi

rm -rf "$TMP"
echo ""
if [ "$fails" -eq 0 ]; then echo "cli tests: all passed"; else echo "cli tests: $fails failed"; fi
exit "$fails"
