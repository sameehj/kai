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

# Nov 1 corrective change: release builds keep the Internet wall in Watch. A
# policy that asks for Protect (egress block) is ignored, and status says so.
H5="$TMP/h5"; mkdir -p "$H5/.kai"
cp "$ROOT/policy/default.policy" "$H5/.kai/policy"
sed -i '' 's/^egress  *log$/egress block/' "$H5/.kai/policy" 2>/dev/null || sed -i 's/^egress  *log$/egress block/' "$H5/.kai/policy"
grep -q '^egress block' "$H5/.kai/policy" && pass "test policy asks for Protect (egress block)" || fail "couldn't set egress block in the test policy"
st=$(HOME="$H5" KAI_NO_APP=1 "$REL" status 2>&1)
case "$st" in *"records the connections it observes; blocks nothing in this release"*) pass "release status: Internet watching, blocks nothing in this release" ;;
     *) fail "release status doesn't say Internet blocks nothing: $(printf '%s' "$st" | grep -i internet)" ;; esac
case "$st" in *"your policy asks for Protect; this release only watches"*) pass "...and says the policy's Protect is ignored" ;;
     *) fail "release status doesn't say the policy's Protect is ignored" ;; esac
case "$st" in *"upcoming release"*) fail "release status still promises OS protection in an upcoming release" ;;
     *) pass "...no 'upcoming release' promise" ;; esac
mode=$(HOME="$H5" KAI_NO_APP=1 "$REL" policy egress-mode 2>&1)
[ "$mode" = "log" ] && pass "release: the effective Internet mode is watch (log) despite egress block" || fail "release effective mode: $mode"
mode=$(HOME="$H5" KAI_HOME="$H5/.kai" KAI_NO_APP=1 "$DEV" policy egress-mode 2>&1)
[ "$mode" = "block" ] && pass "dev build: Protect is still honoured (developer flag territory)" || fail "dev effective mode: $mode"

snap=$(HOME="$H5" KAI_NO_APP=1 "$REL" snapshot --json 2>&1)
case "$snap" in *Enforced*) fail "release snapshot says Enforced: $snap" ;; *) pass "release build: the session list never says Enforced" ;; esac
sl=$(HOME="$H5" KAI_NO_APP=1 "$REL" status 2>&1)
case "$sl" in *Enforced*) fail "release status says Enforced" ;; *) pass "release build: status never says Enforced" ;; esac

# STEP 2c: a release kai never writes hooks that point at a build or checkout
# path, and ignores the tests' override.
H6="$TMP/h6"; mkdir -p "$H6/.claude"; printf '{}' > "$H6/.claude/settings.json"
o=$(HOME="$H6" KAI_TEST_ALLOW_DEV_HOOK=1 KAI_NO_APP=1 "$REL" install claude 2>&1); rc=$?
[ $rc -eq 2 ] && pass "release: install refuses its own build path, override or not" || fail "release install from build/: exit $rc $o"
case "$(cat "$H6/.claude/settings.json")" in *"hook claude"*) fail "release wrote hooks to a build path" ;; *) pass "...and wrote no hooks" ;; esac

# Step 8: an agent's environment can't shrink the rotation size to push
# history out of the log (only one rotated file is kept).
H3="$TMP/h3"; mkdir -p "$H3/.kai"
for i in 1 2 3 4 5 6 7 8; do
    printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"r","tool_input":{"file_path":"'"$H3"'/.ssh/id_rsa"},"cwd":"/tmp"}' \
        | HOME="$H3" KAI_AUDIT_MAX_BYTES=300 KAI_NO_APP=1 "$REL" hook claude >/dev/null 2>&1
done
[ -f "$H3/.kai/audit.log" ] && [ ! -e "$H3/.kai/audit.log.1" ] \
    && pass "release: KAI_AUDIT_MAX_BYTES is ignored (no forced rotation)" || fail "release honoured KAI_AUDIT_MAX_BYTES"
H4="$TMP/h4"; mkdir -p "$H4/.kai"
for i in 1 2 3 4 5 6 7 8; do
    printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"r","tool_input":{"file_path":"'"$H4"'/.ssh/id_rsa"},"cwd":"/tmp"}' \
        | HOME="$H4" KAI_HOME="$H4/.kai" KAI_AUDIT_MAX_BYTES=300 KAI_NO_APP=1 "$DEV" hook claude >/dev/null 2>&1
done
[ -e "$H4/.kai/audit.log.1" ] && pass "dev: KAI_AUDIT_MAX_BYTES is honoured (tests use it)" || fail "dev ignored KAI_AUDIT_MAX_BYTES"

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
