#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Browser integration tests: talk to `kai` exactly as Chrome does (native
# messaging: 32-bit length + JSON), and check `kai install chrome`.
# Everything runs in a throwaway HOME. Needs python3.
set -u
KAI="$(cd "$(dirname "${1:-./kai}")" && pwd)/$(basename "${1:-./kai}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
export HOME="$TMP" KAI_HOME="$TMP/.kai"
unset KAI_POLICY
trap 'rm -rf "$TMP"' EXIT INT TERM
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (got: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1 (unexpected: $2)" ;; *) pass "$1" ;; esac; }
ORIGIN="chrome-extension://bfefkchkkleigcefbgligmkknhmdnhee/"
# talk <json>... : send each message in one session, print one reply per line
talk() { python3 -I "$HERE/native_client.py" "$KAI" "$ORIGIN" "$@"; }

"$KAI" init >/dev/null
"$KAI" policy add term block CONFIDENTIAL >/dev/null
"$KAI" policy add term 'replace:"Project X"' Project Falcon >/dev/null

echo "== native messaging host =="
has "ping answers with version" "$(talk '{"type":"ping"}')" '"version":"'

r=$(talk '{"type":"scan","text":"deploy with AKIAIOSFODNN7EXAMPLE now","site":"chatgpt.com"}')
has "secret found" "$r" '"worst":"redact"'
hasnt "cleaned text has no secret" "$(printf '%s' "$r" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["cleaned"])')" 'AKIAIOSFODNN7EXAMPLE'
has "secret can be overridden by the user" "$r" '"can_override":true'
has "hits name the rule" "$r" '"rule":"secret:aws_access_key"'

r=$(talk '{"type":"scan","text":"this doc is CONFIDENTIAL","site":"claude.ai"}')
has "block term found" "$r" '"worst":"block"'
has "block term cannot be overridden" "$r" '"can_override":false'

has "codename replaced" "$(talk '{"type":"scan","text":"status of Project Falcon?","site":"x"}')" 'Project X'
has "clean text passes" "$(talk '{"type":"scan","text":"how do I sort a list in python","site":"x"}')" '"worst":"none"'

r=$(talk '{"type":"ping"}' '{"type":"scan","text":"key AKIAIOSFODNN7EXAMPLE","site":"x"}' '{"type":"ping"}')
[ "$(printf '%s\n' "$r" | grep -c '"ok":true')" = 3 ] && pass "several messages in one session" || fail "session handling (got: $r)"

has "unknown request is an error" "$(talk '{"type":"nope"}')" '"ok":false'
has "garbage is an error, not a crash" "$(talk 'not json')" '"ok":false'

talk '{"type":"decision","site":"chatgpt.com","action":"redacted","summary":"secret:aws_access_key x1 (redact)"}' >/dev/null
talk '{"type":"decision","site":"claude.ai","action":"sent_anyway","summary":"secret:github_token x1 (redact)"}' >/dev/null
log=$("$KAI" log tail)
has "redaction recorded" "$log" '"source":"browser","event":"chatgpt.com","decision":"redact"'
has "override recorded as warning" "$log" '"event":"claude.ai","decision":"warn"'
hasnt "audit log never holds the secret" "$log" 'AKIAIOSFODNN7EXAMPLE'
"$KAI" log verify >/dev/null && pass "audit chain intact" || fail "audit chain broken"

echo "== install chrome =="
case "$(uname -s)" in
  Darwin) BR="$HOME/Library/Application Support/Google/Chrome" ;;
  *) BR="$HOME/.config/google-chrome" ;;
esac
out=$("$KAI" install chrome 2>&1)
has "no browser: clear message" "$out" "No Chrome"
mkdir -p "$BR"
"$KAI" install chrome >/dev/null 2>&1
M="$BR/NativeMessagingHosts/io.github.sameehj.kai.json"
[ -f "$M" ] && pass "host manifest written" || fail "host manifest missing"
m=$(cat "$M" 2>/dev/null)
has "manifest points at this kai" "$m" "\"path\": \"$KAI\""
has "manifest allows only the Kai extension" "$m" "$ORIGIN"
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$M" && pass "manifest is valid JSON" || fail "manifest JSON invalid"
[ -f "$KAI_HOME/browser-extension/manifest.json" ] && pass "extension copied to ~/.kai/browser-extension" || fail "extension not copied"
[ ! -e "$KAI_HOME/browser-extension/kai-browser-test.html" ] && pass "test page not copied" || fail "test page copied"
has "status points at the copied extension" "$("$KAI" status --json)" "$KAI_HOME/browser-extension"
has "status reports chrome installed" "$("$KAI" status --json)" '"chrome":	{
		"installed":	true'
"$KAI" uninstall chrome >/dev/null
[ ! -f "$M" ] && pass "uninstall removes the manifest" || fail "manifest still there"

echo ""
if [ "$fails" -eq 0 ]; then echo "browser tests: all passed"; else echo "browser tests: $fails failed"; fi
exit "$fails"
