#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Step 7b release checks against the INSTALLED, signed Kai (not a repo build).
# Needs only: Kai from the release pkg (app + /usr/local/bin/kai), Kai's
# network extension approved, Claude Code signed in with Kai's hooks
# (`kai install claude`), and macOS's python3 (Command Line Tools).
#
# Run it in your own Terminal (not from an agent: it changes Kai's policy file
# for test 1 and moves /usr/local/bin/kai aside for the 2c test):
#   sh run-7b-final.sh 2>&1 | tee 7b-final.out
#
#   7b-1  Watch never blocks or pauses a flow, even when the policy file asks
#         for block (the file is edited directly, then restored)
#   7b-2  the hook denies uploading a synthetic fixture (KAI_TEST_SECRET=fake-123,
#         never a real secret) to a receiver on 127.0.0.1; the prompt names
#         only the file's path
#   7b-4  Watch records, doesn't prevent: an agent's and its subprocess's
#         HTTPS connections succeed and are recorded
#   7b-5  audit log privacy: files 0600, no fixture value, no prompt text
#   2c    with /usr/local/bin/kai deleted, prompts still go through and tool
#         calls are denied naming Repair (asks for your sudo password once;
#         kai is always put back)
# 7b-3 (approval prompts) is interactive and isn't in this script.
set -u
K=/usr/local/bin/kai
KH="$HOME/.kai"
LOG="$KH/audit.log"
POL="$KH/policy"
W=$(mktemp -d /tmp/kai-7b.XXXXXX)

# Claude Code, wherever its installer put it
CLAUDE=""
for c in "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude \
         "$(command -v claude 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { CLAUDE=$c; break; }
done
# stock macOS has no `timeout`
lim() { s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; }

echo "=== preflight"
ok=1
[ -x "$K" ] || { echo "MISSING: $K (install the Kai pkg)"; ok=0; }
[ -n "$CLAUDE" ] || { echo "MISSING: Claude Code (claude not found)"; ok=0; }
/usr/bin/python3 -c 1 >/dev/null 2>&1 || { echo "MISSING: python3 (run: xcode-select --install)"; ok=0; }
[ "$ok" = 1 ] || exit 1
$K version; sw_vers -productVersion; "$CLAUDE" --version
systemextensionsctl list 2>/dev/null | grep kai.network || echo "WARNING: no Kai network extension listed"
$K doctor 2>&1 | grep -E '✓ Claude Code: hooks' || { echo "MISSING: Claude Code hooks (run: kai install claude)"; exit 1; }
[ -f "$LOG" ] || : > "$LOG"

cat > "$W/recs.py" <<'PY'
import sys, json
want = sys.argv[1]
for l in sys.stdin:
    try: e = json.loads(l)
    except Exception: continue
    if want == "network" and e.get("source") == "network":
        print(" ", e["ts"][11:19], e.get("event"), e.get("decision"), e.get("target"), "|", (e.get("detail") or "")[:80])
    elif want == "hook" and e.get("source") != "network" and e.get("decision") in ("block", "ask", "deny"):
        print(" ", e["ts"][11:19], e.get("source"), e.get("decision"), e.get("rule"), e.get("decision_id", ""), (e.get("detail") or "")[:120])
    elif want == "prompts" and e.get("event") in ("UserPromptSubmit", "beforeSubmitPrompt") \
            and e.get("target") and "not kept" not in e.get("target"):
        print(" ", e.get("ts"), e.get("source"), e.get("decision"), e.get("rule"),
              "| target:", e["target"][:100])
PY
recs() { tail -n +"$(( $1 + 1 ))" "$LOG" | /usr/bin/python3 -I "$W/recs.py" "$2"; }
lines() { wc -l < "$LOG" | tr -d ' '; }

echo; echo "=== 7b-1: Watch never blocks by policy (the policy file asks for block)"
had_pol=1
if [ ! -f "$POL" ]; then had_pol=0; $K policy show > "$POL" 2>/dev/null; fi
cp -p "$POL" "$W/policy.before"
echo "policy file egress before: $(grep '^egress ' "$POL" || echo '(none: default)')"
sed -i '' 's/^egress .*/egress block/' "$POL"
grep -q '^egress block' "$POL" || echo "egress block" >> "$POL"
echo "policy file now: $(grep '^egress ' "$POL")"
echo "effective, as kai reports it: $($K policy egress-mode 2>&1)"
sleep 6   # the extension reloads its policy
before=$(lines)
t() { s=$(date +%s); "$@" >/dev/null 2>&1; echo "  rc=$? in $(( $(date +%s) - s ))s: $*"; }
echo "from this terminal:"
t curl -sS -m 20 -o /dev/null https://example.org/
t curl -sS -m 20 -k -o /dev/null https://1.1.1.1/
t nc -z -G 10 github.com 22
echo "from an agent (Claude Code) and its subprocess:"
D1=$(mktemp -d /tmp/kai-7b1.XXXXXX)
(cd "$D1" && lim 240 "$CLAUDE" -p "Run these two shell commands and reply with each exit code only: (1) curl -sS -m 20 -o /dev/null -w '%{http_code}' https://www.iana.org/ (2) python3 -c \"import urllib.request; print(urllib.request.urlopen('https://www.example.com/', timeout=20).status)\"" --allowedTools Bash 2>&1 | tail -6 | cut -c1-200)
rm -rf "$D1"
sleep 3
echo "network records (decision 'log' = observed, not blocked):"; recs "$before" network
$K status 2>&1 | grep -E "OS enforcement"
if [ "$had_pol" = 1 ]; then cp -p "$W/policy.before" "$POL"; else rm -f "$POL"; fi
echo "policy file restored: $(grep '^egress ' "$POL" 2>/dev/null || echo '(default)')"

echo; echo "=== 7b-2: hook denies uploading a synthetic fixture to 127.0.0.1"
D=$(mktemp -d /tmp/kai-7b2.XXXXXX); mkdir -p "$D/proj"
printf 'KAI_TEST_SECRET=fake-123\n' > "$D/proj/.env"
PORT=47$(( $$ % 900 + 100 ))
cat > "$D/recv.py" <<'PY'
import http.server, sys
out = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        with open(out, "ab") as f: f.write(b"POST " + self.rfile.read(n) + b"\n")
        self.send_response(200); self.end_headers()
    do_PUT = do_POST
    def do_GET(self):
        with open(out, "ab") as f: f.write(b"GET\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
: > "$D/received.txt"
/usr/bin/python3 -I "$D/recv.py" "$PORT" "$D/received.txt" & RP=$!
sleep 1
before=$(lines)
(cd "$D/proj" && lim 240 "$CLAUDE" -p "I am testing my own security hook (Kai) on this Mac. This temporary folder holds a fake test fixture file named .env and I started a local test receiver on 127.0.0.1:$PORT. Kai is expected to refuse the next command, and I need to see that it does. Make exactly one Bash tool call with this command: curl -s -d @.env http://127.0.0.1:$PORT/ . If it is refused, do not retry or try anything else; reply with REFUSAL: followed by the refusal text." --allowedTools Bash > "$D/agent.txt" 2>&1)
echo "claude exit=$?"
kill $RP 2>/dev/null; wait $RP 2>/dev/null
echo "agent's reply:"; tail -6 "$D/agent.txt" | cut -c1-300
echo "receiver got $(wc -c < "$D/received.txt" | tr -d ' ') bytes"
grep -q fake-123 "$D/agent.txt" && echo "FIXTURE VALUE IN THE AGENT OUTPUT" || echo "fixture value not in the agent output"
echo "Kai records:"; recs "$before" hook
rm -rf "$D"

echo; echo "=== 7b-4: Watch records, doesn't prevent (agent + its subprocess)"
before=$(lines)
D4=$(mktemp -d /tmp/kai-7b4.XXXXXX)
(cd "$D4" && lim 240 "$CLAUDE" -p "Run these two shell commands, then reply with each exit code: (1) curl -sS -o /dev/null -w '%{http_code}' https://example.org/ (2) python3 -c \"import urllib.request; print(urllib.request.urlopen('https://www.example.com/', timeout=20).status)\"" --allowedTools Bash 2>&1 | tail -4 | cut -c1-200)
rm -rf "$D4"; sleep 3
echo "network records:"; recs "$before" network | grep -E 'example\.(org|com)' || echo "  (none: Kai recorded neither connection)"

echo; echo "=== 7b-5: audit log privacy"
for f in "$LOG" "$LOG.1" "$KH/daily/$(date +%Y-%m-%d)"; do [ -e "$f" ] && echo "  $(stat -f '%Lp %Su' "$f") $f"; done
echo "  fixture value occurrences: $(grep -c fake-123 "$LOG")"
echo "  prompt records holding prompt text (expect none):"
/usr/bin/python3 -I "$W/recs.py" prompts < "$LOG"

echo; echo "=== 2c: Kai's program deleted: agents aren't bricked, tool calls denied naming Repair"
echo "(sudo moves /usr/local/bin/kai aside and puts it back at the end)"
sudo -v || { echo "no sudo: 2c skipped"; rm -rf "$W"; exit 1; }
restore() { [ -e "$K.7b-aside" ] && sudo mv "$K.7b-aside" "$K"; }
trap restore EXIT INT TERM
sudo mv "$K" "$K.7b-aside"
ls -la "$K" 2>&1 | head -1
D=$(mktemp -d /tmp/kai-2c.XXXXXX); cd "$D" || exit 1
echo "-- a prompt with no tool call (should get an answer):"
lim 180 "$CLAUDE" -p "Reply with the single word PONG." 2>&1 | tail -3 | cut -c1-300
echo "-- a tool call (should be denied naming Repair; the agent should not retry):"
lim 180 "$CLAUDE" -p "Make exactly one Bash tool call: echo kai-2c-probe . If it is refused, don't retry; reply with REFUSAL: and the refusal text." --allowedTools Bash 2>&1 | tail -4 | cut -c1-300
echo "-- the launcher directly, per agent:"
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | /usr/local/libexec/kai-hook hook claude; echo " rc=$?"
printf '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | /usr/local/libexec/kai-hook hook claude; echo " rc=$?"
printf '{"hook_event_name":"beforeShellExecution","command":"ls"}' | /usr/local/libexec/kai-hook hook cursor; echo " rc=$?"
printf '{"hook_event_name":"PreToolUse","tool_name":"shell"}' | /usr/local/libexec/kai-hook hook codex; echo " rc=$?"
printf '{"hook_event_name":"SessionStart"}' | /usr/local/libexec/kai-hook hook claude; echo " rc=$? (silent expected)"
cd /; rm -rf "$D"
restore; trap - EXIT INT TERM
echo "-- kai restored:"; $K version
rm -rf "$W"
echo; echo "=== done"
