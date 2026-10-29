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
rm -rf "$OUT"
exit $rc
