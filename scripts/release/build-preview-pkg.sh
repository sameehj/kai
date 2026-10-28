#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Kai Preview 1 package (Release Plan v2.1, A3): a Universal (arm64 + x86_64),
# macOS 13+ `kai` CLI in a signed, notarized and stapled .pkg, plus SHA-256
# checksums. One tagged commit in, one artifact out.
#
#   KAI_DEVID_APP="Developer ID Application: Name (TEAMID)" \
#   KAI_DEVID_INSTALLER="Developer ID Installer: Name (TEAMID)" \
#   KAI_NOTARY_PROFILE=kai-notary \
#   sh scripts/release/build-preview-pkg.sh 0.2.0-preview.1
#
# Without the Developer ID identities and a notarytool keychain profile
# (xcrun notarytool store-credentials kai-notary ...) it REFUSES to make a
# release. `--test` makes an unsigned package for local install tests only,
# named *-UNSIGNED-TEST.pkg so it can't be mistaken for a release.
set -eu
VERSION="${1:?usage: build-preview-pkg.sh <version> [--test]}"
MODE="${2:-release}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/release"
STAGE="$OUT/stage"
cd "$ROOT"

if [ "$MODE" != "--test" ]; then
    [ -n "${KAI_DEVID_APP:-}" ] && [ -n "${KAI_DEVID_INSTALLER:-}" ] && [ -n "${KAI_NOTARY_PROFILE:-}" ] || {
        echo "release needs KAI_DEVID_APP, KAI_DEVID_INSTALLER and KAI_NOTARY_PROFILE (or --test)"; exit 2; }
    [ -z "$(git status --porcelain)" ] || { echo "release needs a clean tree (one tagged commit)"; exit 2; }
    tag="v$VERSION"
    [ "$(git describe --exact-match --tags 2>/dev/null || true)" = "$tag" ] || {
        echo "HEAD must be tagged $tag"; exit 2; }
fi

grep -q "#define KAI_VERSION \"$VERSION\"" include/kai.h || {
    echo "include/kai.h KAI_VERSION isn't \"$VERSION\""; [ "$MODE" = "--test" ] || exit 2; }

rm -rf "$OUT" && mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/share/kai" "$OUT/scripts"

# Universal, macOS 13+ (remove only the objects: `make clean` would also wipe build/)
rm -f src/*.o third_party/cjson/*.o kai libkai.a
make CC="cc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0" kai >/dev/null
lipo -info kai | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "kai isn't universal"; exit 1; }
cp kai "$STAGE/usr/local/bin/kai"
cp policy/default.policy "$STAGE/usr/local/share/kai/default.policy"
mkdir -p "$STAGE/usr/local/share/kai/browser/icons"
cp integrations/browser/*.js integrations/browser/*.json integrations/browser/popup.html \
   "$STAGE/usr/local/share/kai/browser/"
cp integrations/browser/icons/*.png "$STAGE/usr/local/share/kai/browser/icons/"

# preinstall: never install an older kai over a newer one (A4)
cat > "$OUT/scripts/preinstall" <<EOF
#!/bin/sh
new="$VERSION"
if [ -x /usr/local/bin/kai ]; then
    cur=\$(/usr/local/bin/kai version 2>/dev/null | awk '{print \$2}')
    newest=\$(printf '%s\n%s\n' "\$cur" "\$new" | sort -V | tail -1)
    if [ -n "\$cur" ] && [ "\$newest" = "\$cur" ] && [ "\$cur" != "\$new" ]; then
        echo "Kai \$cur is installed; this package is the older \$new. Nothing changed." >&2
        exit 1
    fi
fi
exit 0
EOF
chmod +x "$OUT/scripts/preinstall"

ID=io.github.sameehj.kai.preview
if [ "$MODE" = "--test" ]; then
    PKG="$OUT/Kai-Preview-$VERSION-UNSIGNED-TEST.pkg"
    pkgbuild --root "$STAGE" --identifier "$ID" --version "$VERSION" --scripts "$OUT/scripts" \
             --install-location / "$PKG" >/dev/null
    echo "UNSIGNED test package (not for release): $PKG"
else
    codesign --force --options runtime --timestamp --sign "$KAI_DEVID_APP" "$STAGE/usr/local/bin/kai"
    codesign --verify --strict "$STAGE/usr/local/bin/kai"
    COMP="$OUT/component.pkg"
    pkgbuild --root "$STAGE" --identifier "$ID" --version "$VERSION" --scripts "$OUT/scripts" \
             --install-location / "$COMP" >/dev/null
    PKG="$OUT/Kai-Preview-$VERSION.pkg"
    productbuild --package "$COMP" --sign "$KAI_DEVID_INSTALLER" --timestamp "$PKG" >/dev/null
    rm -f "$COMP"
    xcrun notarytool submit "$PKG" --keychain-profile "$KAI_NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
    spctl --assess --type install -vv "$PKG"
fi
( cd "$OUT" && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256" )
cat "$OUT/$(basename "$PKG").sha256"
[ "$MODE" = "--test" ] || \
    echo "next (a person publishes): gh release create v$VERSION --prerelease \"$PKG\" \"$PKG.sha256\""
