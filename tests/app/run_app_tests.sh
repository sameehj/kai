#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Pure app-model tests (no UI, no KaiCore): compiled with swiftc from the app's
# Foundation-only files. Skipped where there is no swiftc (Linux CI).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v swiftc >/dev/null 2>&1 || { echo "app tests: skipped (no swiftc)"; exit 0; }
OUT="$(mktemp -d)"
S="$ROOT/app/macos/Sources/KaiBar"
cp "$ROOT/tests/app/reach_main.swift" "$OUT/main.swift"
swiftc -O -o "$OUT/reach" "$S/AuditLog.swift" "$S/Reach.swift" "$OUT/main.swift" || exit 1
"$OUT/reach"; rc=$?
# Decision-card buttons at the popover's width (SwiftUI, offscreen). The
# snapshots stay in KAI_CARD_SNAPSHOTS when set.
mkdir -p "$OUT/cards"
cp "$ROOT/tests/app/cards_main.swift" "$OUT/cards/main.swift"
swiftc -O -o "$OUT/cards/run" "$S/Theme.swift" "$S/Info.swift" "$S/CardActions.swift" "$OUT/cards/main.swift" || exit 1
"$OUT/cards/run" "${KAI_CARD_SNAPSHOTS:-$OUT/cards}" || rc=1
rm -rf "$OUT"
# The app decodes the built kai's real `kai snapshot --json` with its own
# types, so app and CLI can't drift apart.
if [ -x "$ROOT/kai" ]; then
    SO="$(mktemp -d)"
    mkdir -p "$SO/home/.kai"
    KAI_HOME="$SO/home/.kai" "$ROOT/kai" snapshot --json > "$SO/snap.json" || { echo "  FAIL kai snapshot --json"; rc=1; }
    cp "$ROOT/tests/app/sessions_main.swift" "$SO/main.swift"
    swiftc -O -o "$SO/run" "$S/Sessions.swift" "$SO/main.swift" || exit 1
    "$SO/run" "$SO/snap.json" || rc=1
    rm -rf "$SO"
else
    echo "  FAIL no ./kai to decode (build it first)"; rc=1
fi
# Kai's sounds: every cue KaiSound.swift names ships in kai-sfx/ (the app
# bundles that folder's .wav files as top-level resources).
for cue in $(sed -n 's/.*case [a-zA-Z]* = "\(kai-[a-z-]*\)".*/\1/p' "$S/KaiSound.swift"); do
    if [ -s "$ROOT/kai-sfx/$cue.wav" ]; then echo "  ok   sound $cue.wav ships"; else echo "  FAIL sound $cue.wav missing"; rc=1; fi
done
exit $rc
