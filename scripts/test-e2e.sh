#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_HOME="$(mktemp -d)"
TMP_WORK="$(mktemp -d)"
TMP_BIN="$(mktemp -d)"
KAI_BIN="$ROOT_DIR/bin/kai"
CODX_SRC="$TMP_WORK/codex.go"
CODX_BIN="$TMP_BIN/codex"
LOG_FILE="$TMP_WORK/watch.log"

cleanup() {
  set +e
  if [[ -n "${WATCH_PID:-}" ]]; then kill "$WATCH_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "${CODX_PID:-}" ]]; then kill "$CODX_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "${DAEMON_PID:-}" ]]; then kill "$DAEMON_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP_HOME" "$TMP_WORK" "$TMP_BIN"
}
trap cleanup EXIT

if [[ ! -x "$KAI_BIN" ]]; then
  echo "building kai binary..."
  mkdir -p "$ROOT_DIR/bin"
  go build -o "$KAI_BIN" ./cmd/kai
fi

cat > "$CODX_SRC" <<'GO'
package main

import "time"

func main() {
	for i := 0; i < 5; i++ {
		time.Sleep(1 * time.Second)
	}
}
GO

GO111MODULE=off go build -o "$CODX_BIN" "$CODX_SRC"

export HOME="$TMP_HOME"
mkdir -p "$HOME/.kai"

# Start daemon in foreground backgrounded by shell.
"$KAI_BIN" daemon run >"$TMP_WORK/daemon.log" 2>&1 &
DAEMON_PID=$!

# Wait for socket
for _ in $(seq 1 50); do
  [[ -S "$HOME/.kai/kai.sock" ]] && break
  sleep 0.2
done
[[ -S "$HOME/.kai/kai.sock" ]] || { echo "daemon socket not ready"; exit 1; }

# Start watch stream
"$KAI_BIN" watch --agent codex >"$LOG_FILE" 2>&1 &
WATCH_PID=$!
sleep 0.4

# Trigger an attributed codex session
"$CODX_BIN" &
CODX_PID=$!

# Trigger file activity in daemon cwd tree
E2E_FILE="$ROOT_DIR/.e2e_kai_tmp.txt"
echo "hello" > "$E2E_FILE"
echo "world" >> "$E2E_FILE"
rm -f "$E2E_FILE"

wait "$CODX_PID"
sleep 2

# Validate sessions/replay output
SESS_OUT="$($KAI_BIN sessions --agent codex --limit 5 || true)"
[[ "$SESS_OUT" == *"CODEX"* ]] || { echo "expected CODEX session, got: $SESS_OUT"; exit 1; }

REPLAY_OUT="$($KAI_BIN replay last --agent codex || true)"
[[ "$REPLAY_OUT" == *"SESSION"* ]] || { echo "expected replay output, got: $REPLAY_OUT"; exit 1; }

WATCH_TEXT="$(cat "$LOG_FILE" || true)"
[[ "$WATCH_TEXT" == *"CODEX"* ]] || { echo "expected CODEX in watch output, got: $WATCH_TEXT"; exit 1; }

echo "e2e ok"
