#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# The Preview package's postinstall: registers kai for the console user only,
# as that user with that user's HOME, and skips (with a note) when nobody is
# signed in. launchctl is replaced by a recorder, so nothing is installed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PI="$ROOT/scripts/release/postinstall"
TMP="$(mktemp -d)"
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/launchctl" <<EOF
#!/bin/sh
echo "\$@" >> "$TMP/calls"
# simulate kai install changing Claude Code's settings in the fake home
case "\$*" in *"HOME=$TMP/home "*"install claude"*) echo " " >> "$TMP/home/.claude/settings.json" ;; esac
EOF
chmod +x "$TMP/bin/launchctl"
me=$(id -un); myuid=$(id -u)
myhome=$(dscl . -read "/Users/$me" NFSHomeDirectory | awk '{print $2}')

echo "== postinstall =="
out=$(PATH="$TMP/bin:$PATH" KAI_CONSOLE_USER="$me" sh "$PI"); rc=$?
call=$(cat "$TMP/calls" 2>/dev/null)
[ "$rc" = 0 ] && pass "exits 0" || fail "exit $rc"
case "$call" in
    *"asuser $myuid sudo -u $me -H env HOME=$myhome /usr/local/bin/kai install chrome"*) pass "runs kai install chrome as the console user, with that user's HOME" ;;
    *) fail "unexpected call: $call" ;;
esac
case "$out" in *"registered kai with $me"*) pass "notes it in the installer log" ;; *) fail "no note: $out" ;; esac

for who in root loginwindow ""; do
    rm -f "$TMP/calls"
    out=$(PATH="$TMP/bin:$PATH" KAI_CONSOLE_USER="$who" sh "$PI"); rc=$?
    if [ "$rc" = 0 ] && [ ! -e "$TMP/calls" ] && case "$out" in *"nobody is signed in"*) true ;; *) false ;; esac; then
        pass "console '${who:-<none>}': skipped with a note, nothing run"
    else
        fail "console '${who:-<none>}': rc=$rc calls=$(cat "$TMP/calls" 2>/dev/null) out=$out"
    fi
done

echo "== refresh agents that already have Kai's hooks =="
CH="$TMP/home"; mkdir -p "$CH/.claude" "$CH/.codex" "$CH/.cursor"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"/x/kai hook claude"}]}]}}' > "$CH/.claude/settings.json"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"/x/kai hook codex"}]}]}}' > "$CH/.codex/hooks.json"
printf '{"version":1,"hooks":{}}' > "$CH/.cursor/hooks.json"
rm -f "$TMP/calls"
out=$(PATH="$TMP/bin:$PATH" KAI_CONSOLE_USER="$me" KAI_CONSOLE_HOME="$CH" sh "$PI")
calls=$(cat "$TMP/calls" 2>/dev/null)
case "$calls" in *"kai install claude"*) pass "re-installs Claude Code's hooks (it had them)" ;; *) fail "no claude reinstall: $calls" ;; esac
case "$calls" in *"kai install codex"*) pass "re-installs Codex's hooks (it had them)" ;; *) fail "no codex reinstall: $calls" ;; esac
case "$calls" in *"kai install cursor"*) fail "touched Cursor, which had no Kai hooks" ;; *) pass "leaves an agent without Kai's hooks alone" ;; esac
case "$calls" in *"asuser $myuid sudo -u $me -H env HOME=$CH /usr/local/bin/kai install claude"*) pass "...as the console user, with that user's HOME" ;; *) fail "wrong user/home: $calls" ;; esac
case "$out" in *"Claude Code: hooks updated"*"backups kept"*) pass "logs what changed, and that backups are kept" ;; *) fail "no change log: $out" ;; esac
case "$out" in *"Codex: hooks already current"*) pass "...and what didn't change" ;; *) fail "no unchanged note: $out" ;; esac

rm -f "$TMP/calls"
out=$(PATH="$TMP/bin:$PATH" KAI_CONSOLE_USER=daemon sh "$PI"); rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/calls" ] && pass "a system account at the console: skipped" || fail "system account: $out"
grep -q "/var/root" "$TMP/calls" 2>/dev/null && fail "touched root's home" || pass "never root's home"

rm -rf "$TMP"
echo ""
if [ "$fails" -eq 0 ]; then echo "postinstall tests: all passed"; else echo "postinstall tests: $fails failed"; fi
exit "$fails"
