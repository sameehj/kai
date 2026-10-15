#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Build build/Kai.app: the menu-bar app with the kai CLI bundled inside.
# Usage: app/macos/build-app.sh [--universal]   (run `make` first)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/app/macos"
OUT="$ROOT/build/Kai.app"
VERSION="$(sed -n 's/^#define KAI_VERSION "\(.*\)"/\1/p' "$ROOT/include/kai.h")"

ARCHS=""
if [ "${1:-}" = "--universal" ]; then ARCHS="--arch arm64 --arch x86_64"; fi

# shellcheck disable=SC2086
swift build --package-path "$PKG" -c release $ARCHS
BIN="$(swift build --package-path "$PKG" -c release $ARCHS --show-bin-path)/KaiBar"

[ -x "$ROOT/kai" ] || { echo "build the CLI first: make" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Kai"
cp "$ROOT/kai" "$OUT/Contents/Resources/kai"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kai</string>
  <key>CFBundleDisplayName</key><string>Kai</string>
  <key>CFBundleIdentifier</key><string>io.github.sameehj.kai</string>
  <key>CFBundleExecutable</key><string>Kai</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0 · The Kai Authors</string>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough to run locally. Release builds should use a
# Developer ID identity and notarization instead.
codesign --force --sign "${KAI_SIGN_IDENTITY:--}" "$OUT/Contents/Resources/kai"
codesign --force --sign "${KAI_SIGN_IDENTITY:--}" "$OUT"
echo "built $OUT"
