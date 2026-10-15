#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Gateway tests: run `kai gateway` against a fake upstream and check exactly
# what would have left the machine. Needs python3 and curl.
set -u
KAI="$(cd "$(dirname "${1:-./kai}")" && pwd)/$(basename "${1:-./kai}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
export HOME="$TMP" KAI_HOME="$TMP/.kai"
unset KAI_POLICY
UP=$((20000 + $$ % 20000)); GW=$((UP + 1))
LOG="$TMP/upstream.jsonl"; : > "$LOG"
export KAI_GATEWAY_ANTHROPIC="http://127.0.0.1:$UP"
export KAI_GATEWAY_OPENAI="http://127.0.0.1:$UP/oa"
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (got: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1 (unexpected: $2)" ;; *) pass "$1" ;; esac; }
last() { tail -n 1 "$LOG"; }
post() { curl -sS -m 10 -H 'content-type: application/json' -H 'x-api-key: test-key-123' \
              -H 'anthropic-version: 2023-06-01' "$@"; }

"$KAI" init >/dev/null
"$KAI" policy add term block CONFIDENTIAL >/dev/null
"$KAI" policy add term 'replace:"Project X"' Project Falcon >/dev/null
python3 -I "$HERE/fake_upstream.py" "$UP" "$LOG" & UPID=$!
"$KAI" gateway --port "$GW" 2>"$TMP/gw.err" & GPID=$!
trap 'kill $UPID $GPID 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -s "http://127.0.0.1:$GW/_kai/health" >/dev/null 2>&1 &&
    curl -s -X POST -d '{}' "http://127.0.0.1:$UP/ping" >/dev/null 2>&1 && break
  sleep 0.2
done
: > "$LOG"
G="http://127.0.0.1:$GW"

echo "== gateway =="
has "health endpoint" "$(curl -s "$G/_kai/health")" '"ok":true'

out=$(post -d '{"model":"m","messages":[{"role":"user","content":"deploy with AKIAIOSFODNN7EXAMPLE now"}]}' "$G/v1/messages")
has "clean request is forwarded" "$out" '"echo_path": "/v1/messages"'
req=$(last)
hasnt "secret never reaches upstream" "$req" 'AKIAIOSFODNN7EXAMPLE'
has "secret replaced by marker" "$req" 'REDACTED by Kai'
has "api key header forwarded" "$req" '"x-api-key": "test-key-123"'
has "anthropic-version forwarded" "$req" '"anthropic-version": "2023-06-01"'

post -d '{"messages":[{"role":"user","content":[{"type":"text","text":"status of Project Falcon?"}]}]}' "$G/v1/messages" >/dev/null
has "codename replaced in nested content" "$(last)" 'Project X'

n_before=$(wc -l < "$LOG")
code=$(post -o "$TMP/blocked.json" -w '%{http_code}' -d '{"messages":[{"role":"user","content":"this is CONFIDENTIAL"}]}' "$G/v1/messages")
has "blocked term gets 403" "$code" "403"
has "anthropic-style error body" "$(cat "$TMP/blocked.json")" '"type":"permission_error"'
[ "$(wc -l < "$LOG")" = "$n_before" ] && pass "blocked request never sent upstream" || fail "blocked request reached upstream"

img="AKIAIOSFODNN7EXAMPLEAAAAbase64imagedata"
post -d "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"$img\"}}]}]}" "$G/v1/messages" >/dev/null
has "base64 image data left intact" "$(last)" "$img"

code=$(post -o "$TMP/oa.json" -w '%{http_code}' -d '{"messages":[{"role":"user","content":"CONFIDENTIAL"}]}' "$G/openai/v1/chat/completions")
has "openai route blocks too" "$code" "403"
has "openai-style error body" "$(cat "$TMP/oa.json")" '"type":"kai_blocked"'
post -d '{"messages":[{"role":"user","content":"hi"}]}' "$G/openai/v1/chat/completions" >/dev/null
has "openai prefix routed upstream" "$(last)" '"path": "/oa/v1/chat/completions"'

post -H 'Transfer-Encoding: chunked' --data-binary '{"messages":[{"role":"user","content":"key AKIAIOSFODNN7EXAMPLE"}]}' "$G/v1/messages" >/dev/null
hasnt "chunked request body cleaned" "$(last)" 'AKIAIOSFODNN7EXAMPLE'

start=$(python3 -I -c 'import time; print(time.time())')
first=$(post -N -d '{"stream":true}' "$G/v1/stream" | python3 -I -c '
import sys, time
t0 = float(sys.argv[1]); first = None; n = 0
for line in sys.stdin:
    if line.startswith("data:"):
        n += 1
        if first is None: first = time.time() - t0
print(n, round(first or 99, 2))' "$start")
has "all streamed events arrive" "$first" "3 "
fsec=${first#* }
python3 -I -c "import sys; sys.exit(0 if float('$fsec') < 0.5 else 1)" && pass "first event streams before the last ($fsec s)" || fail "response was buffered (first event at $fsec s)"

has "audit log records gateway redaction" "$(cat "$KAI_HOME/audit.log")" '"source":"gateway"'
"$KAI" log verify >/dev/null && pass "audit chain intact after concurrent writes" || fail "audit chain broken"

kill $UPID 2>/dev/null; wait $UPID 2>/dev/null
code=$(post -o "$TMP/down.json" -w '%{http_code}' -d '{"messages":[]}' "$G/v1/messages")
has "upstream down gives 502" "$code" "502"

echo ""
if [ "$fails" -eq 0 ]; then echo "gateway tests: all passed"; else echo "gateway tests: $fails failed"; fi
exit "$fails"
