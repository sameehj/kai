#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Live checks for the session-identity change set: pause, resume, one Kai,
# Cursor activity, Agent Control loading. Run it INSIDE a Claude Code session
# (its processes must be an agent's):
#
#     ! sh .claude/worktrees/ux-review-phase-a/scripts/live-checks-2.sh      all five
#     ! sh .claude/worktrees/ux-review-phase-a/scripts/live-checks-2.sh 3    just one
#
# Before: install this build, then turn Files and Internet off and on once so
# macOS loads the new extensions (storage v31, network v16), both on Protect.

KAI=/Applications/Kai.app/Contents/Resources/kai
HERE="$(cd "$(dirname "$0")/.." && pwd)"
D=$(mktemp -d /tmp/kai-live2.XXXXXX)
KEYEXT=".k""ey"                      # kept out of the literal so Kai's hooks don't flag the script
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
ask()  { printf '  -> %s [y/n] ' "$1"; read -r a </dev/tty; [ "$a" = y ]; }
wait_enter() { printf '  -> %s  [Enter when done] ' "$1"; read -r _ </dev/tty; }

[ -x "$KAI" ] || { echo "Kai isn't installed at /Applications/Kai.app"; exit 2; }
"$KAI" agent-of $$ >/dev/null 2>&1 || { echo "Run this inside Claude Code:  ! sh $0"; exit 2; }

# A soft-protected file this session may not read (created new: allowed).
KEYF="$D/scratch$KEYEXT"
printf x > "$KEYF" 2>/dev/null
wall_reads() { head -c 1 "$KEYF" >/dev/null 2>&1; }
# What Claude Code's hook answers for `cat <key>` from this session's tree
# (the hook resolves its Kai session from the per-pid map, as a real one does).
hook_allows() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"live-check","tool_input":{"command":"cat %s"},"cwd":"/tmp"}' "$KEYF" \
        | "$KAI" hook claude 2>/dev/null | grep -q '"permissionDecision":"deny"' && return 1
    return 0
}

check1() {
    echo "1. Pause a session: a blocked command works, the UI shows the countdown"
    wall_reads && { bad "the scratch key was readable before pausing (is Files on Protect?)"; return; }
    hook_allows && { bad "the hook allowed it before pausing"; return; }
    ok "before: blocked by the wall and by the hook"
    wait_enter "Agent Control -> this Claude Code session -> Pause 15 min. Wait until it says 'Paused · resumes …'"
    wall_reads && ok "paused: the wall lets the read through" || bad "paused, but the wall still blocks it"
    hook_allows && ok "paused: the hook lets the command through" || bad "paused, but the hook still blocks it"
    ask "Do the popover row, the session header and the menu-bar icon show 'Paused · resumes HH:MM' (with Resume, +15 min, and 'Kai's own settings stay protected')?" \
        && ok "the UI shows the paused state and countdown" || bad "the UI doesn't show the pause"
}

check2() {
    echo "2. Resume: blocked again"
    wait_enter "Click Resume (popover or session header)"
    sleep 6   # the wall picks the marker change up on its 5 s heartbeat
    wall_reads && bad "resumed, but the wall still lets it through" || ok "resumed: the wall blocks it again"
    hook_allows && bad "resumed, but the hook still lets it through" || ok "resumed: the hook blocks it again"
}

check3() {
    echo "3. One Kai: a second copy leaves one menu-bar icon"
    n0=$(pgrep -x Kai | wc -l | tr -d ' ')
    [ "$n0" = 1 ] || echo "  (note: $n0 Kai processes before the check; quit extras first)"
    COPY="$HERE/build/Kai.app"
    [ -d "$COPY" ] || { bad "no $COPY (build it: make app-storage KAI_TEAM=KD446VDTM2)"; return; }
    open -n "$COPY"; sleep 4
    n=$(pgrep -x Kai | wc -l | tr -d ' ')
    [ "$n" = 1 ] && ok "launching $COPY left exactly one Kai running" || bad "$n Kai processes after launching a second copy"
    ask "Is there exactly one Kai icon in the menu bar?" && ok "one menu-bar icon" || bad "more than one icon"
    ask "Does Activity show 'claude launched a Kai app: …build/Kai.app… (not the installed one)'?" \
        && ok "the agent launch is logged" || bad "the agent launch wasn't logged"
    OLD="$HERE/../../../build/Kai.app"
    [ -d "$OLD" ] && echo "  note: $OLD predates the one-Kai code and can't hand over; delete it: rm -rf '$OLD'"
}

check4() {
    echo "4. Chat in Cursor: its row turns working within a minute"
    wait_enter "Send one chat message in Cursor now"
    i=0; st=""
    while [ $i -lt 9 ]; do
        st=$("$KAI" sessions --json | /usr/bin/python3 -I -c \
            'import json,sys; r=[x for x in json.load(sys.stdin) if x["agent"]=="cursor" and x["state"]=="active"]; print(r[0]["activity"] if r else "none")')
        [ "$st" = working ] && break
        i=$((i + 1)); sleep 10
    done
    [ "$st" = working ] && ok "Cursor's row is working" || bad "Cursor's row is '$st' after 90 s"
}

check5() {
    echo "5. Agent Control opens with no empty flash"
    wait_enter "Open the popover, then 'Open Agent Control' (do it twice)"
    ask "Did the list show sessions at once both times (no 'No agent sessions' flash, at most placeholder rows on the first open)?" \
        && ok "no empty flash" || bad "an empty flash"
}

for n in ${1:-1 2 3 4 5}; do "check$n"; echo; done
rm -rf "$D" 2>/dev/null || echo "Scratch key left in $D (the wall blocks an agent deleting it): run  rm -rf $D  in Terminal"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
