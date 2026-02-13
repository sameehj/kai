#!/usr/bin/env bash
set -euo pipefail

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f ".env" ]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    line="${line#export }"
    key="${line%%=*}"
    val="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    if [ -n "$key" ] && [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < .env
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY is not set. E2E tests require a real LLM." >&2
  exit 1
fi

mkdir -p build

go build -o build/kai ./cmd/kai

./build/kai gateway > /tmp/kai-gateway.log 2>&1 &
GATEWAY_PID=$!

echo "Gateway PID: $GATEWAY_PID"

cleanup() {
  kill "$GATEWAY_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for gateway
for i in {1..20}; do
  if curl -s http://127.0.0.1:18789/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  if [ "$i" -eq 20 ]; then
    echo "Gateway did not start" >&2
    exit 1
  fi
done

# Create test skill
mkdir -p skills/test-skill
cat > skills/test-skill/SKILL.md << 'SKILL'
---
name: test-skill
description: Test skill used by e2e
---

# Test Skill

## When to use
- When asked to use test-skill

## How to use
Run:

exec {"command": "echo skill-ok"}
SKILL

python - << 'PY'
import json, subprocess, sys, os, time

def rpc_call(proc, msg_id, content):
    req = {
        "jsonrpc": "2.0",
        "id": msg_id,
        "method": "message",
        "params": {"content": content},
    }
    body = json.dumps(req)
    header = "Content-Length: {}\r\n\r\n".format(len(body.encode("utf-8")))
    proc.stdin.write(header)
    proc.stdin.write(body)
    proc.stdin.flush()

    # read header
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError("No response header")
    if not line.startswith("Content-Length:"):
        raise RuntimeError(f"Unexpected header: {line}")
    length = int(line.split(":", 1)[1].strip())
    # read blank line
    blank = proc.stdout.readline()
    if blank.strip() != "":
        raise RuntimeError("Missing header terminator")
    data = proc.stdout.read(length)
    return json.loads(data)

def ensure_ok(resp, label):
    if "error" in resp and resp["error"] is not None:
        raise RuntimeError(f"{label} RPC error: {resp['error']}")

proc = subprocess.Popen(["./build/kai", "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

try:
    # Test 1: Basic response
    resp1 = rpc_call(proc, 1, "hello")
    ensure_ok(resp1, "hello")
    content1 = resp1.get("result", {}).get("content", "")
    assert content1.strip(), f"Empty response for hello: {resp1}"

    # Test 2: Tool invocation
    resp2 = rpc_call(proc, 2, "what system am I on?")
    ensure_ok(resp2, "system-info")
    content2 = resp2.get("result", {}).get("content", "")
    assert content2.strip(), f"Empty response for system info: {resp2}"

    # Test 3: Multi-step tool loop
    resp3 = rpc_call(proc, 3, "list files in this directory")
    ensure_ok(resp3, "ls")
    content3 = resp3.get("result", {}).get("content", "")
    assert content3.strip(), f"Empty response for ls: {resp3}"

    # Test 4: Skill usage
    resp4 = rpc_call(proc, 4, "use test-skill")
    ensure_ok(resp4, "test-skill")
    content4 = resp4.get("result", {}).get("content", "")
    assert content4.strip(), f"Empty response for test-skill: {resp4}"
finally:
    proc.terminate()

# Validate session file
session_path = os.path.expanduser("~/.kai/sessions/agent:main:main.json")
assert os.path.exists(session_path), "Session file was not created"

with open(session_path, "r", encoding="utf-8") as f:
    data = json.load(f)

text = json.dumps(data)

# Expectations
assert "tool_calls" in text, "No tool_calls found in session"
assert "exec" in text or "ls" in text, "Expected tool call not found"
assert "\"name\":\"ls\"" in text or "ls" in text, "Expected ls tool call missing"
assert "test-skill" in text, "Skill name not present in session"

print("E2E tests passed")
PY
