#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# CLI tests: status, policy editing and install/uninstall, all inside a
# throwaway HOME so nothing on the machine is touched.
set -u
KAI="$(cd "$(dirname "${1:-./kai}")" && pwd)/$(basename "${1:-./kai}")"
TMP="$(mktemp -d)"
export HOME="$TMP" KAI_HOME="$TMP/.kai"
unset KAI_POLICY
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
# has(name, haystack, needle)
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (got: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1 (unexpected: $2)" ;; *) pass "$1" ;; esac; }
count() { printf '%s' "$1" | grep -c "$2"; }

echo "== status =="
out=$("$KAI" status --json)
has "status is json with version" "$out" '"version"'
has "status: built-in policy before init" "$out" '"source":	"built-in"'
has "status: claude not installed" "$out" '"installed":	false'

echo "== policy set =="
"$KAI" policy set on_upload ask >/dev/null
has "set creates the policy file" "$(ls "$KAI_HOME")" "policy"
has "set changes the switch" "$("$KAI" policy show --json)" '"on_upload":	"ask"'
"$KAI" policy set on_upload block >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" '^on_upload')" = 1 ] && pass "set replaces in place" || fail "set duplicated the line"
"$KAI" policy set on_upload maybe >/dev/null 2>&1 && fail "bad value accepted" || pass "bad value rejected"
"$KAI" policy set nonsense 1 >/dev/null 2>&1 && fail "unknown switch accepted" || pass "unknown switch rejected"

echo "== protect / allow =="
"$KAI" policy add protect ~/secret-stuff >/dev/null
has "add protect" "$("$KAI" policy show --json)" 'secret-stuff'
"$KAI" policy add protect ~/secret-stuff >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" 'secret-stuff')" = 1 ] && pass "add protect is idempotent" || fail "add protect duplicated"
"$KAI" policy remove protect ~/secret-stuff >/dev/null
hasnt "remove protect" "$(cat "$KAI_HOME/policy")" 'secret-stuff'
"$KAI" policy remove protect ~/never-there >/dev/null 2>&1 && fail "removing missing entry succeeded" || pass "removing missing entry fails"

echo "== terms and rules =="
"$KAI" policy add term 'replace:"Project X"' Project Falcon >/dev/null
has "term shows in json" "$("$KAI" policy show --json)" '"replacement":	"Project X"'
has "term is enforced" "$(printf 'about Project Falcon' | "$KAI" redact)" 'Project X'
"$KAI" policy add term block Project Falcon >/dev/null
[ "$(count "$(cat "$KAI_HOME/policy")" 'Project Falcon')" = 1 ] && pass "re-adding a term updates it" || fail "term duplicated"
"$KAI" policy remove term Project Falcon >/dev/null
hasnt "remove term" "$(cat "$KAI_HOME/policy")" 'Project Falcon'
"$KAI" policy add rule bad_rule block '([unclosed' >/dev/null 2>&1 && fail "invalid regex accepted" || pass "invalid regex rejected"
hasnt "rejected change not written" "$(cat "$KAI_HOME/policy")" 'bad_rule'
"$KAI" policy add rule corp_host redact 'internal-[a-z]+[.]corp' >/dev/null
has "rule is enforced" "$(printf 'host internal-db.corp ok' | "$KAI" redact)" 'REDACTED'
"$KAI" policy remove rule corp_host >/dev/null
hasnt "remove rule" "$(cat "$KAI_HOME/policy")" 'corp_host'

echo "== install / uninstall =="
mkdir -p "$HOME/.claude"
printf '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$HOME/.claude/settings.json"
"$KAI" install claude >/dev/null
"$KAI" install claude >/dev/null
[ "$(count "$(cat "$HOME/.claude/settings.json")" 'hook claude')" = 4 ] && pass "install twice adds hooks once" || fail "install duplicated hooks"
has "status: claude installed" "$("$KAI" status --json)" '"installed":	true'
"$KAI" uninstall claude >/dev/null
s=$(cat "$HOME/.claude/settings.json")
hasnt "uninstall removes kai hooks" "$s" 'hook claude'
has "uninstall keeps user hooks" "$s" 'echo mine'
has "uninstall keeps other settings" "$s" '"theme"'

rm -rf "$TMP"
echo ""
if [ "$fails" -eq 0 ]; then echo "cli tests: all passed"; else echo "cli tests: $fails failed"; fi
exit "$fails"
