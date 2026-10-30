#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Release builds ignore KAI_HOME and KAI_POLICY from the environment (hooks,
# CLI, the app's library); only dev and test builds honour them, so an agent
# (or a stray test variable) can't point a real install at another home.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

echo "== release builds ignore KAI_HOME / KAI_POLICY =="
make -C "$ROOT" kai-release >/dev/null 2>&1 || { fail "make kai-release"; exit 1; }
REL="$ROOT/build/kai-release"
DEV="$ROOT/kai"
H="$TMP/home"; mkdir -p "$H/.kai"
printf 'protect ~/.ssh\n' > "$TMP/other.policy"

v=$("$REL" version)
case "$v" in *"(release build)"*) pass "kai version says release build" ;; *) fail "release version: $v" ;; esac
case "$("$DEV" version)" in *"(dev build"*) pass "...and a dev build says so" ;; *) fail "dev version" ;; esac

p=$(HOME="$H" KAI_HOME="$TMP/elsewhere" KAI_POLICY="$TMP/other.policy" "$REL" policy path)
[ "$p" = "$H/.kai/policy" ] && pass "release: KAI_HOME and KAI_POLICY are ignored ($p)" || fail "release honoured env: $p"
p=$(HOME="$H" KAI_HOME="$TMP/elsewhere" KAI_POLICY="$TMP/other.policy" "$DEV" policy path)
[ "$p" = "$TMP/other.policy" ] && pass "dev: they are honoured" || fail "dev ignored env: $p"

printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"r","tool_input":{"file_path":"'"$H"'/.ssh/id_rsa"},"cwd":"/tmp"}' \
    | HOME="$H" KAI_HOME="$TMP/elsewhere" KAI_NO_APP=1 "$REL" hook claude >/dev/null
[ -f "$H/.kai/audit.log" ] && [ ! -e "$TMP/elsewhere/audit.log" ] \
    && pass "release hook: the record goes to the real home, never to KAI_HOME" \
    || fail "release hook logged to KAI_HOME"

# Where the policy fingerprint lands: the release binary never in KAI_HOME,
# the test binary (tests/cli/kai-test, which the suites drive) always there.
# CI once ran the integrity tests before kai-test existed; this pins both sides.
TB="$ROOT/tests/cli/kai-test"
H2="$TMP/h2"; X="$TMP/x"; mkdir -p "$H2" "$X"
HOME="$H2" KAI_HOME="$X" KAI_NO_APP=1 "$REL" init >/dev/null 2>&1
[ -f "$H2/.kai/policy.sha256" ] && [ ! -e "$X/policy.sha256" ] \
    && pass "release kai init: the fingerprint is written under \$HOME/.kai, never in KAI_HOME" \
    || fail "release init wrote to KAI_HOME (or nowhere)"
if [ -x "$TB" ]; then
    case "$("$TB" version)" in *"dev build: honours KAI_HOME"*) pass "the test binary is a dev build" ;; *) fail "tests/cli/kai-test isn't a dev build" ;; esac
    H3="$TMP/h3"; Y="$TMP/y"; mkdir -p "$H3" "$Y"
    HOME="$H3" KAI_HOME="$Y" "$TB" init >/dev/null 2>&1
    [ -f "$Y/policy.sha256" ] && [ ! -e "$H3/.kai/policy.sha256" ] \
        && pass "test binary kai init: the fingerprint is written in KAI_HOME (the sandbox)" \
        || fail "test binary ignored KAI_HOME"
else
    fail "tests/cli/kai-test missing (make test builds it before the suites)"
fi

rm -rf "$TMP"
echo ""
if [ "$fails" -eq 0 ]; then echo "release env tests: all passed"; else echo "release env tests: $fails failed"; fi
exit "$fails"
