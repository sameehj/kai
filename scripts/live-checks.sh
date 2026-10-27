#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# The five live checks for the UX-review build (Phase A + follow-up fixes),
# before the dogfood day. Run it INSIDE a Claude Code session, so its processes
# are an agent's (that is what the walls act on):
#
#     ! sh scripts/live-checks.sh            all five, in order
#     ! sh scripts/live-checks.sh 3          just check 3
#
# Before: install the build (make try-app-storage KAI_TEAM=KD446VDTM2), approve
# both extensions and Full Disk Access, and set Files and Internet to Protect.
# Some checks ask you to click in Kai; the script waits for Enter, then
# verifies. Every check prints PASS or FAIL; it changes nothing it doesn't
# undo, and writes its scratch files under a temp dir and ~/.claude.

KAI=/Applications/Kai.app/Contents/Resources/kai
HB="$HOME/Library/Group Containers/KD446VDTM2.io.github.sameehj.kai/network-health.json"
D=$(mktemp -d /tmp/kai-live.XXXXXX)
KEYEXT=".k""ey"                     # kept out of the literal so Kai's hooks don't flag the script itself
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
wait_enter() { printf '  -> %s  [Enter when done] ' "$1"; read -r _ </dev/tty; }
denied() { ! "$@" >/dev/null 2>&1; }   # the command failed (the wall denied it)
net_mode() { "$KAI" status --json | /usr/bin/python3 -I -c \
    'import json,sys; print(json.load(sys.stdin)["walls"]["configured"]["network"])'; }

[ -x "$KAI" ] || { echo "Kai isn't installed at /Applications/Kai.app"; exit 2; }
if ! "$KAI" agent-of $$ >/dev/null 2>&1; then
    echo "This shell is not an agent's. Run it inside Claude Code:  ! sh scripts/live-checks.sh"
    exit 2
fi
echo "Running as: $("$KAI" agent-of $$)"

# 1. Agents use their own working files; others' secrets stay protected.
check1() {
    echo "1. Own working files"
    if [ -f "$HOME/.claude/daemon/control$KEYEXT" ]; then
        head -c 1 "$HOME/.claude/daemon/control$KEYEXT" >/dev/null 2>&1 \
            && ok "Claude Code reads its own ~/.claude/daemon/control key" \
            || bad "Claude Code was denied its own control key"
    else
        echo "  (no ~/.claude/daemon/control key on this Mac; using a scratch one)"
    fi
    own="$HOME/.claude/kai-livecheck$KEYEXT"
    printf x > "$own" 2>/dev/null && head -c 1 "$own" >/dev/null 2>&1 \
        && ok "a key-named file inside ~/.claude is usable by Claude Code" \
        || bad "a key-named file inside ~/.claude was blocked"
    rm -f "$own"
    other="$D/server$KEYEXT"
    printf x > "$other" 2>/dev/null || true          # creating a new one is allowed (logged)
    if [ -f "$other" ]; then
        denied cat "$other" && ok "an existing key outside ~/.claude is still denied" \
                            || bad "a key outside the agent's state was readable"
    else
        bad "couldn't create the scratch key (expected: create allowed, read denied)"
    fi
}

# 2. A Touch ID approval for a WRITE is honored (break-glass verifier).
check2() {
    echo "2. Touch ID write approval"
    t="$HOME/.ssh/kai-livecheck.txt"
    if ! denied sh -c "printf x >> '$t'"; then
        bad "writing into ~/.ssh wasn't blocked to begin with (is Files on Protect?)"; rm -f "$t"; return
    fi
    ok "write into ~/.ssh blocked; a card should ask for Touch ID"
    wait_enter "In Kai's popover: on that card click \"Allow for 15 minutes (Touch ID)\" and authenticate"
    sh -c "printf x >> '$t'" 2>/dev/null && ok "the approved write went through" \
                                       || bad "the write was still denied after Touch ID"
    rm -f "$t" 2>/dev/null
    wait_enter "Optional: revoke it in Kai (Agent Control -> this session -> Revoke)"
}

# 3. No dead ends: a never-tier block shows an "Always protected" card.
check3() {
    echo "3. No dead ends"
    denied cat "$HOME/.kai/policy" && ok "reading Kai's own policy is denied" \
                                  || bad "Kai's own policy was readable by an agent"
    printf '  -> Does Kai show a card "... wanted to read Kai'"'"'s own settings", marked "Always protected", with Dismiss and Why? [y/n] '
    read -r a </dev/tty
    [ "$a" = y ] && ok "Always-protected card shown" || bad "no card / wrong card for a never-tier block"
}

# 4. Turning protection down asks for Touch ID right away, then applies.
check4() {
    echo "4. Turning protection down"
    before=$(net_mode)
    wait_enter "In Kai Settings -> Internet, choose Watch. Touch ID should appear at once; approve it"
    after=$(net_mode)
    [ "$after" = log ] && ok "Internet changed $before -> log after Touch ID" \
                       || bad "Internet is '$after' (expected log): the change didn't apply"
    printf '  -> Did a pending "turn protection down" card stay behind in the popover? [y/n] '
    read -r a </dev/tty
    [ "$a" = n ] && ok "no leftover pending card" || bad "a pending card lingered"
    wait_enter "Now choose Protect again (tightening: applies with no prompt)"
    now=$(net_mode)
    [ "$now" = block ] && ok "Internet back to Protect" || bad "Internet is '$now', expected block"
}

# 5. Verified status + Pause reaches real sessions.
check5() {
    echo "5. Verified status and Pause"
    if [ -f "$HB" ] && [ "$(stat -f %u "$HB")" = 0 ] && [ $(( $(date +%s) - $(stat -f %m "$HB") )) -le 30 ]; then
        ok "network heartbeat is root-owned and fresh in the app-group container"
    else
        bad "no fresh root-owned network heartbeat at $HB (Console: filter 'heartbeat write failed')"
    fi
    "$KAI" status | head -2 | sed 's/^/      /'
    "$KAI" status | head -1 | grep -q "^Protected" && ok "headline: Protected (both walls verified)" \
        || bad "headline isn't Protected (see above)"
    "$KAI" sessions | grep -q "^scan-" && bad "a session still shows a scan- id (not mapped to the wall)" \
        || ok "sessions carry the wall's ids (no scan- ids)"
    other="$D/server$KEYEXT"
    [ -f "$other" ] || printf x > "$other" 2>/dev/null
    wait_enter "In the popover click \"Pause Kai for 15 minutes\""
    "$KAI" status | head -1 | grep -q "Kai is paused" && ok "status says Kai is paused" || bad "status doesn't show the pause"
    cat "$other" >/dev/null 2>&1 && ok "while paused, a soft-protected read goes through (logged)" \
                                 || bad "paused, but the soft-protected read was still denied"
    denied cat "$HOME/.kai/policy" && ok "while paused, Kai's own policy stays protected" \
                                  || bad "pause exposed Kai's own policy"
    wait_enter "Click Resume in the popover"
    denied cat "$other" && ok "after Resume, the read is denied again" || bad "still allowed after Resume"
}

for n in ${1:-1 2 3 4 5}; do "check$n"; echo; done
# Deleting the scratch key is a write the wall (correctly) denies an agent;
# remove it from your own Terminal instead.
rm -rf "$D" 2>/dev/null || echo "Scratch key left in $D (the wall blocks an agent deleting it): run  rm -rf $D  in Terminal"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
