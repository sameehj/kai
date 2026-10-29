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
EOF
chmod +x "$TMP/bin/launchctl"
me=$(id -un); myuid=$(id -u)
myhome=$(dscl . -read "/Users/$me" NFSHomeDirectory | awk '{print $2}')

echo "== postinstall =="
out=$(PATH="$TMP/bin:$PATH" KAI_CONSOLE_USER="$me" sh "$PI"); rc=$?
call=$(cat "$TMP/calls" 2>/dev/null)
[ "$rc" = 0 ] && pass "exits 0" || fail "exit $rc"
case "$call" in
    "asuser $myuid sudo -u $me -H env HOME=$myhome /usr/local/bin/kai install chrome") pass "runs kai install chrome as the console user, with that user's HOME" ;;
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

rm -f "$TMP/calls"
out=$(PATH="$TMP/bin:$PATH" KAI_CONSOLE_USER=daemon sh "$PI"); rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/calls" ] && pass "a system account at the console: skipped" || fail "system account: $out"
grep -q "/var/root" "$TMP/calls" 2>/dev/null && fail "touched root's home" || pass "never root's home"

rm -rf "$TMP"
echo ""
if [ "$fails" -eq 0 ]; then echo "postinstall tests: all passed"; else echo "postinstall tests: $fails failed"; fi
exit "$fails"
