#!/bin/bash
set -e

echo "=== OpenClaw Adherence Tests ==="

./build/kai gateway &
GATEWAY_PID=$!
sleep 2

echo "what system am I on?" | ./build/kai chat > /tmp/kai-test.txt

if grep -q "exec" /tmp/kai-test.txt; then
    echo "✅ Agent used exec primitive"
else
    echo "❌ Agent did not use primitives"
    kill $GATEWAY_PID
    exit 1
fi

if [ -f ~/.kai/sessions/agent:main:main.json ]; then
    echo "✅ Session saved"
else
    echo "❌ No session file"
    kill $GATEWAY_PID
    exit 1
fi

if [ -f AGENTS.md ]; then
    echo "✅ Workspace model working"
else
    echo "❌ No workspace files"
    kill $GATEWAY_PID
    exit 1
fi

kill $GATEWAY_PID

echo "All tests passed"
