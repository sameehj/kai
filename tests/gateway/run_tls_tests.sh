#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Step 5 — the gateway is a TLS client to the model APIs, and it must reject a
# bad upstream certificate (fail closed) rather than carry traffic over a
# connection it cannot trust. We stand up local HTTPS servers with a
# self-signed, an expired, and a wrong-hostname certificate, point the gateway
# at each through the test-only KAI_GATEWAY_ANTHROPIC override, and require a
# 502 (refused) every time. A plain non-TLS upstream (the existing
# run_gateway_tests.sh suite) proves a good upstream flows through.
#
# Needs: the kai-test binary (built with KAI_TEST_DIRECT_POLICY so the env
# override is honoured), openssl, python3. Uses a throwaway KAI_HOME; never the
# real one.
set -u
KAI="${1:?usage: run_tls_tests.sh <kai-binary>}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kai-tls.XXXXXX")"
export KAI_HOME="$WORK/home"
mkdir -p "$KAI_HOME"
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

fail=0
pass=0
check() { # desc  expected-substring  actual
  if printf '%s' "$3" | grep -q "$2"; then echo "  ok   $1"; pass=$((pass+1));
  else echo "  FAIL $1 (got: $3)"; fail=$((fail+1)); fi
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# $1 subject/CN opts for openssl -subj, $2 days (negative = already expired), $3 cert out, $4 key out
make_cert() {
  subj="$1"; days="$2"; crt="$3"; key="$4"
  if [ "$days" -lt 0 ]; then
    # An already-expired cert: issue with a start date well in the past and a
    # one-day life so notAfter is also in the past.
    faketime_days=$(( -days ))
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$crt" \
      -days 1 -subj "$subj" \
      -not_before "$(date -u -v-${faketime_days}d +%Y%m%d%H%M%SZ 2>/dev/null || date -u -d "-${faketime_days} days" +%Y%m%d%H%M%SZ)" \
      -not_after  "$(date -u -v-$((faketime_days-1))d +%Y%m%d%H%M%SZ 2>/dev/null || date -u -d "-$((faketime_days-1)) days" +%Y%m%d%H%M%SZ)" \
      >/dev/null 2>&1
  else
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$crt" \
      -days "$days" -subj "$subj" >/dev/null 2>&1
  fi
}

start_tls_server() { # cert key -> echoes port, records pid
  crt="$1"; key="$2"; port="$(free_port)"
  python3 - "$crt" "$key" "$port" >/dev/null 2>&1 <<'PY' &
import ssl, sys, http.server
crt, key, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(crt, key)
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", port), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
  pids="$pids $!"
  # wait for the port to accept
  for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2);
try:
 s.connect(('127.0.0.1',$port)); s.close()
except Exception: sys.exit(1)" 2>/dev/null; then break; fi
    sleep 0.1
  done
  echo "$port"
}

# Run one case: start a TLS server with the given cert, point the gateway at it,
# send a request, and return the gateway's HTTP status line.
run_case() { # cert key
  up="$(start_tls_server "$1" "$2")"
  gw="$(free_port)"
  KAI_GATEWAY_ANTHROPIC="https://127.0.0.1:$up" "$KAI" gateway --port "$gw" >/dev/null 2>&1 &
  gpid=$!; pids="$pids $gpid"
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2);
try:
 s.connect(('127.0.0.1',$gw)); s.close()
except Exception: sys.exit(1)" 2>/dev/null && break
    sleep 0.1
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$gw/v1/messages" \
          -H 'content-type: application/json' -d '{"model":"x","messages":[]}' 2>/dev/null)"
  kill "$gpid" 2>/dev/null
  echo "$code"
}

echo "== gateway TLS validation =="

make_cert "/CN=127.0.0.1" 365 "$WORK/ss.crt" "$WORK/ss.key"
check "self-signed upstream cert is refused (502)" "502" "$(run_case "$WORK/ss.crt" "$WORK/ss.key")"

make_cert "/CN=127.0.0.1" -400 "$WORK/exp.crt" "$WORK/exp.key"
check "expired upstream cert is refused (502)" "502" "$(run_case "$WORK/exp.crt" "$WORK/exp.key")"

make_cert "/CN=example.com" 365 "$WORK/wh.crt" "$WORK/wh.key"
check "wrong-hostname upstream cert is refused (502)" "502" "$(run_case "$WORK/wh.crt" "$WORK/wh.key")"

echo
if [ "$fail" -eq 0 ]; then echo "gateway TLS tests: all passed ($pass checks)"; exit 0
else echo "gateway TLS tests: $fail failed"; exit 1; fi
