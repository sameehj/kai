#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# make screenshots: the README's pictures, from the real SwiftUI views and a
# FIXTURE data set (app/macos/Sources/KaiBar/Screenshots.swift), never live
# data. Light and dark, @2x PNG, into assets/screenshots/.
#
#   sh scripts/screenshots.sh [watch|blocklist]
#
# The Internet picture shows "Watch + block my list" only for a release whose
# network blocking was verified on a real Mac (S5); pass "watch" otherwise.
# Runs a Debug build; the renderer sets a time zone that puts "now" at 10:40, so every clock
# in the pictures reads between 09:00 and 11:00. Needs Xcode and xcodegen.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-blocklist}"
OUT="$ROOT/assets/screenshots"
cd "$ROOT"
( cd app/macos && KAI_APP_ID=io.github.sameehj.kai.dev xcodegen generate --quiet )
xcodebuild -project app/macos/Kai.xcodeproj -scheme Kai -configuration Debug -derivedDataPath build/dd \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= -quiet build
APP="$ROOT/build/dd/Build/Products/Debug/Kai.app/Contents/MacOS/Kai"
TMP="$(mktemp -d)"
"$APP" --kai-screenshots "$TMP" --internet "$MODE" >/dev/null 2>&1 || true
n=0
for f in now activity ask popover internet stop-detail; do
    for v in "" "-dark"; do
        src="$TMP/$f$v.png"
        [ -s "$src" ] || { echo "screenshots: $f$v.png wasn't rendered"; exit 1; }
        dst="$OUT/$f$v.png"
        if command -v pngquant >/dev/null 2>&1; then
            pngquant --quality 70-95 --strip --force --output "$dst" "$src"
        else
            cp "$src" "$dst"
        fi
        size=$(stat -f %z "$dst" 2>/dev/null || stat -c %s "$dst")
        if [ "$size" -gt 409600 ]; then   # keep each under 400 KB
            sips -s format png -Z 1800 "$dst" --out "$dst" >/dev/null
            size=$(stat -f %z "$dst" 2>/dev/null || stat -c %s "$dst")
        fi
        [ "$size" -le 409600 ] || { echo "screenshots: $f$v.png is $size bytes (over 400 KB)"; exit 1; }
        echo "  $f$v.png  $(( size / 1024 )) KB"
        n=$(( n + 1 ))
    done
done
rm -rf "$TMP"
echo "screenshots: $n pictures in assets/screenshots (Internet: $MODE)"
