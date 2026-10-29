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
exit $rc
