#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Activity recorder: on by default since 0.4.1, metadata only, daily rotation, 7 days kept;
# 0.5: per-session summaries, health probes not recorded.
set -u
KAI="${1:-./kai}"
TMP="$(mktemp -d)"
export KAI_HOME="$TMP/home"
mkdir -p "$KAI_HOME"
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
hk() { printf '%s' "$2" | "$KAI" hook "$1" >/dev/null 2>&1; }
J_READ='{"hook_event_name":"PreToolUse","cwd":"/tmp/proj","session_id":"s1","tool_name":"Read","tool_input":{"file_path":"src/a.c"}}'
J_WRITE='{"hook_event_name":"PreToolUse","cwd":"/tmp/proj","session_id":"s1","tool_name":"Write","tool_input":{"file_path":"notes.md","content":"KAI_CONTENT_MARKER"}}'
J_CMD='{"hook_event_name":"PreToolUse","cwd":"/tmp/proj","session_id":"s1","tool_name":"Bash","tool_input":{"command":"API_TOKEN=KAI_ENV_MARKER /usr/bin/git commit -m KAI_ARG_MARKER"}}'
J_MCP='{"hook_event_name":"PreToolUse","cwd":"/tmp/proj","session_id":"s1","tool_name":"mcp__gh__search","tool_input":{"q":"KAI_MCP_MARKER"}}'
J_CUR='{"hook_event_name":"beforeShellExecution","command":"npm test KAI_CURSOR_MARKER","workspace_roots":["/tmp/proj"]}'

echo "== activity recorder =="
# 0.4.1: on by default (a policy without the line records); an explicit off is kept
printf 'record_activity off\n' > "$TMP/off.policy"
KAI_POLICY="$TMP/off.policy" hk claude "$J_READ"
[ -f "$KAI_HOME/activity.jsonl" ] && fail "explicit off: a file was written" || pass "explicit off: nothing recorded"
o=$(KAI_POLICY="$TMP/off.policy" "$KAI" activity --json)
case "$o" in *'"recording":false'*) pass "kai activity says recording is off" ;; *) fail "kai activity: $o" ;; esac
printf 'egress log\n' > "$TMP/noline.policy"
KAI_POLICY="$TMP/noline.policy" hk claude "$J_READ"
[ -f "$KAI_HOME/activity.jsonl" ] && pass "on by default: a policy without the line records" || fail "default: nothing recorded"
o=$(KAI_POLICY="$TMP/noline.policy" "$KAI" activity --json)
case "$o" in *'"recording":true'*) pass "kai activity says recording is on" ;; *) fail "kai activity default: $o" ;; esac
rm -f "$KAI_HOME"/activity*.jsonl

printf 'record_activity on\n' > "$TMP/on.policy"
export KAI_POLICY="$TMP/on.policy"
for j in "$J_READ" "$J_READ" "$J_WRITE" "$J_CMD" "$J_MCP"; do hk claude "$j"; done
hk cursor "$J_CUR"
F="$KAI_HOME/activity.jsonl"
[ "$(wc -l < "$F" | tr -d ' ')" = 6 ] && pass "one line per hook call" || fail "lines: $(wc -l < "$F")"
if grep -q MARKER "$F"; then fail "arguments, contents or full commands stored: $(grep MARKER "$F")"; else pass "no arguments, contents or full commands stored"; fi
grep -q '"cmd0":"git"' "$F" && pass "first word of a command only (path and VAR= dropped)" || fail "cmd0: $(cat "$F")"
grep -q '"op":"write","path":"/tmp/proj/notes.md"' "$F" && pass "file tool: op and absolute path" || fail "write row"
grep -q '"op":"mcp","mcp_server":"gh"' "$F" && pass "MCP: server name" || fail "mcp row"
grep -q '"agent":"cursor".*"op":"command","cmd0":"npm"' "$F" && pass "Cursor shell command recorded" || fail "cursor row"
[ "$(stat -f %Lp "$F" 2>/dev/null || stat -c %a "$F")" = 600 ] && pass "file is private (0600)" || fail "mode"

o=$("$KAI" activity --json --since 1h --workspace /tmp/proj)
case "$o" in *'"op":"read","count":2,"distinct":1'*) pass "repeated reads collapsed" ;; *) fail "grouping: $o" ;; esac
o=$("$KAI" activity --json --workspace /tmp/elsewhere)
case "$o" in *'"groups":[]'*) pass "--workspace filters" ;; *) fail "workspace filter: $o" ;; esac

# 0.5: per session (Now cards, the Activity timeline): counts, stops, newest events first
o=$("$KAI" activity --json --since 1h)
case "$o" in *'"sessions":[{'*) pass "kai activity lists sessions" ;; *) fail "sessions: $o" ;; esac
# the key is Kai's session key (pid-<root> under an agent) or, without one, the agent's own session id
case "$o" in *'"key":"conv:s1"'*|*'"key":"pid-'*) pass "sessions keyed by Kai's session key or the agent's session id" ;; *) fail "session key: $o" ;; esac
case "$o" in *'"counts":{"read":2,"edit":0,"write":1,"command":'[12]',"mcp":1,"tool":0}'*) pass "per-session counts by kind" ;; *) fail "counts: $o" ;; esac
case "$o" in *'"events":[{"ts":'*'"op":"mcp","name":"gh"'*) pass "events newest first, MCP by server name" ;; *) fail "events: $o" ;; esac
case "$o" in *MARKER*) fail "session events leak arguments: $o" ;; *) pass "session events hold no arguments or full commands" ;; esac
case "$o" in *'"first_record":'*) pass "first_record says when recording began" ;; *) fail "first_record: $o" ;; esac
# 0.5: a health probe (kai status' self-test) is not agent activity
before=$(wc -l < "$F" | tr -d ' ')
hk claude '{"kai_health_probe":true,"hook_event_name":"PreToolUse","cwd":"/","tool_name":"Read","tool_input":{"file_path":"/x/audit.log"}}'
[ "$(wc -l < "$F" | tr -d ' ')" = "$before" ] && pass "health probe not recorded" || fail "health probe recorded: $(tail -1 "$F")"

# rotation: yesterday's file moves aside; rotated files older than 7 days are deleted
touch -t "$(date -v-1d +%Y%m%d%H%M 2>/dev/null || date -d yesterday +%Y%m%d%H%M)" "$F"
OLD="$KAI_HOME/activity-20000101.jsonl"
echo '{}' > "$OLD"; touch -t 200001010000 "$OLD"
hk claude "$J_READ"
ls "$KAI_HOME"/activity-*.jsonl 2>/dev/null | grep -qv 20000101 && pass "rotated daily" || fail "not rotated: $(ls "$KAI_HOME")"
[ -f "$OLD" ] && fail "a file older than 7 days was kept" || pass "files older than 7 days deleted"
[ "$(wc -l < "$F" | tr -d ' ')" = 1 ] && pass "today's file starts fresh" || fail "today: $(wc -l < "$F")"
unset KAI_POLICY

rm -rf "$TMP"
echo ""
if [ "$fails" -eq 0 ]; then echo "activity recorder tests: all passed"; else echo "activity recorder tests: $fails failed"; fi
exit "$fails"
