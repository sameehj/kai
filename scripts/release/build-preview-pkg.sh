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
#   KAI_STORE_EXTENSION_ID=<the Chrome Web Store ID, 32 letters a-p> \
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
    # The tag must be master as published, and CI must have passed on it.
    git fetch -q origin master --tags || { echo "can't fetch origin to check the tag"; exit 2; }
    head=$(git rev-parse HEAD); tagc=$(git rev-parse "$tag^{commit}"); masterc=$(git rev-parse origin/master)
    [ "$tagc" = "$head" ] && [ "$tagc" = "$masterc" ] || {
        echo "$tag ($tagc) must be origin/master HEAD ($masterc) and checked out"; exit 2; }
    ci=$(gh api "repos/{owner}/{repo}/commits/$tagc/check-runs?per_page=100" \
           --jq '[.check_runs[] | select(.app.slug=="github-actions")] | "\(length) \([.[] | select(.conclusion!="success" and .conclusion!="skipped")] | length)"' 2>/dev/null) \
        || { echo "can't read CI results for $tagc (gh api)"; exit 2; }
    set -- $ci
    [ "${1:-0}" -gt 0 ] && [ "${2:-1}" -eq 0 ] || {
        echo "CI hasn't passed on $tagc: $ci (check runs, not-passed). Wait for green CI on master."; exit 2; }
    echo "build guard: $tag = origin/master = $tagc, CI passed ($1 check runs)"
fi

# The store copy of the browser extension talks to kai only if kai's native
# host lists its ID. A release must have it; a test package may leave it out.
STORE_ID="${KAI_STORE_EXTENSION_ID:-}"
if [ -n "$STORE_ID" ]; then
    printf '%s' "$STORE_ID" | grep -Eq '^[a-p]{32}$' || { echo "KAI_STORE_EXTENSION_ID isn't a Chrome extension ID"; exit 2; }
elif [ "$MODE" != "--test" ]; then
    echo "release needs KAI_STORE_EXTENSION_ID (upload the extension unlisted first: docs/CHROME_STORE.md)"; exit 2
fi

grep -q "#define KAI_VERSION \"$VERSION\"" include/kai.h || {
    echo "include/kai.h KAI_VERSION isn't \"$VERSION\""; [ "$MODE" = "--test" ] || exit 2; }

rm -rf "$OUT" && mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/share/kai" "$OUT/scripts"

# Universal, macOS 13+ (remove only the objects: `make clean` would also wipe build/)
rm -f src/*.o third_party/cjson/*.o kai libkai.a
make CC="cc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0" KAI_STORE_ID="$STORE_ID" kai-release >/dev/null
K=build/kai-release   # a release build: ignores KAI_HOME / KAI_POLICY
[ -z "$STORE_ID" ] || strings "$K" | grep -q "$STORE_ID" || { echo "the store ID didn't make it into kai"; exit 1; }
lipo -info "$K" | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "kai isn't universal"; exit 1; }
"$K" version | grep -q "(release build)" || { echo "kai isn't a release build"; exit 1; }
cp "$K" "$STAGE/usr/local/bin/kai"
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

# postinstall: register kai's native host with the signed-in user's browsers,
# so the store extension can reach kai right away (no Terminal step).
# Console user only; nobody signed in: skipped with a note in the installer log
# (tests/release/run_postinstall_tests.sh).
cp scripts/release/postinstall "$OUT/scripts/postinstall"
chmod +x "$OUT/scripts/postinstall"

ID=io.github.sameehj.kai.preview
# Welcome and readme pages (the Preview 1 contract and the three steps), via a
# distribution file. Both the test and the release package carry them.
RES="$OUT/resources"
mkdir -p "$RES"
cp scripts/release/installer/welcome.html scripts/release/installer/readme.html "$RES/"
[ "$MODE" = "--test" ] || {
    codesign --force --options runtime --timestamp --sign "$KAI_DEVID_APP" "$STAGE/usr/local/bin/kai"
    codesign --verify --strict "$STAGE/usr/local/bin/kai"
}
COMP="$OUT/component.pkg"
pkgbuild --root "$STAGE" --identifier "$ID" --version "$VERSION" --scripts "$OUT/scripts" \
         --install-location / "$COMP" >/dev/null
DIST="$OUT/distribution.xml"
productbuild --synthesize --package "$COMP" "$DIST" >/dev/null
# add the pages and a title right after the opening tag
awk '{print} /<installer-gui-script/ && !done {print "    <title>Kai Preview</title>"; \
     print "    <welcome file=\"welcome.html\" mime-type=\"text/html\"/>"; \
     print "    <readme file=\"readme.html\" mime-type=\"text/html\"/>"; done=1}' "$DIST" > "$DIST.tmp" && mv "$DIST.tmp" "$DIST"
grep -q 'welcome file="welcome.html"' "$DIST" || { echo "distribution file has no welcome page"; exit 1; }
if [ "$MODE" = "--test" ]; then
    PKG="$OUT/Kai-Preview-$VERSION-UNSIGNED-TEST.pkg"
    productbuild --distribution "$DIST" --resources "$RES" --package-path "$OUT" "$PKG" >/dev/null
    rm -f "$COMP"
    echo "UNSIGNED test package (not for release): $PKG"
else
    PKG="$OUT/Kai-Preview-$VERSION.pkg"
    productbuild --distribution "$DIST" --resources "$RES" --package-path "$OUT" \
                 --sign "$KAI_DEVID_INSTALLER" --timestamp "$PKG" >/dev/null
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
