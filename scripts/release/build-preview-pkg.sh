#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Kai release package: Kai.app with its network system extension (Developer
# ID signed, notarized, stapled; Step 7) and a Universal (arm64 + x86_64),
# macOS 13+ `kai` CLI, in a signed, notarized and stapled .pkg, plus SHA-256
# checksums. One tagged commit in, one artifact out. Every check is fatal.
#
#   KAI_TEAM=TEAMID \
#   KAI_DEVID_APP="Developer ID Application: Name (TEAMID)" \
#   KAI_DEVID_INSTALLER="Developer ID Installer: Name (TEAMID)" \
#   KAI_APP_PROFILE=Kai_DeveloperID.provisionprofile \
#   KAI_EXT_PROFILE=KaiNetwork_DeveloperID.provisionprofile \
#   KAI_NOTARY_PROFILE=kai-notary \
#   make release            # = sh scripts/release/build-preview-pkg.sh <version>
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
    for v in KAI_TEAM KAI_DEVID_APP KAI_DEVID_INSTALLER KAI_APP_PROFILE KAI_EXT_PROFILE KAI_NOTARY_PROFILE; do
        eval "[ -n \"\${$v:-}\" ]" || { echo "release needs $v (see the top of this script), or --test"; exit 2; }
    done
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

grep -q "#define KAI_VERSION \"$VERSION\"" include/kai.h || {
    echo "include/kai.h KAI_VERSION isn't \"$VERSION\""; [ "$MODE" = "--test" ] || exit 2; }

rm -rf "$OUT" && mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/share/kai" "$STAGE/Applications" "$OUT/scripts"

# notarytool exits 0 for a rejected submission too: require "status: Accepted".
notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$KAI_NOTARY_PROFILE" --wait > "$OUT/notary.log" 2>&1 || true
    cat "$OUT/notary.log"
    grep -q "status: Accepted" "$OUT/notary.log" || { echo "notarization of $(basename "$1") wasn't accepted"; exit 1; }
}

# Kai.app and its network extension (Step 7): built unsigned for the release
# team, then Developer ID signed, checked, notarized, stapled and checked again.
( cd app/macos && KAI_APP_ID=io.github.sameehj.kai KAI_TEAM="${KAI_TEAM:-}" xcodegen generate --quiet )
xcodebuild -project app/macos/Kai.xcodeproj -scheme Kai -configuration Release -derivedDataPath "$OUT/dd" \
    DEVELOPMENT_TEAM="${KAI_TEAM:-}" CODE_SIGNING_ALLOWED=NO -quiet build
APP="$STAGE/Applications/Kai.app"
cp -R "$OUT/dd/Build/Products/Release/Kai.app" "$APP"
[ -d "$APP/Contents/Library/SystemExtensions/io.github.sameehj.kai.network.systemextension" ] || {
    echo "Kai.app has no network extension"; exit 1; }
[ ! -e "$APP/Contents/Library/SystemExtensions/io.github.sameehj.kai.storage.systemextension" ] || {
    echo "Kai.app contains the storage extension; Files isn't in this release"; exit 1; }
appv=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$appv" = "${VERSION%%-*}" ] || { echo "Kai.app is version $appv, not ${VERSION%%-*} (project.yml MARKETING_VERSION)"; exit 1; }
if [ "$MODE" = "--test" ]; then
    codesign --force --deep --sign - "$APP"   # unsigned test package: ad hoc, the extension won't activate
else
    sh scripts/release/sign-app.sh sign "$APP"
    sh scripts/release/sign-app.sh check "$APP"
    ditto -c -k --keepParent "$APP" "$OUT/Kai-notarize.zip"
    notarize "$OUT/Kai-notarize.zip"
    rm -f "$OUT/Kai-notarize.zip"
    xcrun stapler staple "$APP"
    sh scripts/release/sign-app.sh check "$APP" --notarized
fi

# Universal, macOS 13+ (remove only the objects: `make clean` would also wipe build/)
rm -f src/*.o third_party/cjson/*.o kai libkai.a
make CC="cc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0" kai-release >/dev/null
K=build/kai-release   # a release build: ignores KAI_HOME / KAI_POLICY
lipo -info "$K" | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "kai isn't universal"; exit 1; }
"$K" version | grep -q "(release build)" || { echo "kai isn't a release build"; exit 1; }
"$K" version | grep -q "commit $(git rev-parse --short=12 HEAD)$" || [ "$MODE" = "--test" ] || {
    echo "kai doesn't carry this commit: $("$K" version)"; exit 1; }
cp "$K" "$STAGE/usr/local/bin/kai"
{   # traceable build: what this package was built from, and with what
    echo "kai: $("$K" version)"
    echo "app: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"), network extension build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Library/SystemExtensions/io.github.sameehj.kai.network.systemextension/Contents/Info.plist")"
    echo "commit: $(git rev-parse HEAD)"
    echo "compiler: $(cc --version | head -1)"
    echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    echo "sdk: macOS $(xcrun --show-sdk-version 2>/dev/null)"
    echo "host: macOS $(sw_vers -productVersion)"
    echo "cJSON: v1.7.19 (c859b25) + kai-patches.diff; see THIRD_PARTY.md"
} > "$OUT/BUILDINFO.txt"
cp policy/default.policy "$STAGE/usr/local/share/kai/default.policy"

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

# postinstall: for the signed-in user, remove an earlier Kai's Chrome helper (no
# dangling browser manifest after an upgrade) and refresh existing agent hooks.
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
    ! pkgutil --payload-files "$PKG" | grep -q "kai.storage" || { echo "the package contains the storage extension"; exit 1; }
    pkgutil --check-signature "$PKG" | grep -q "Developer ID Installer" || { echo "package isn't Developer ID Installer signed"; exit 1; }
    notarize "$PKG"
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
    spctl --assess --type install -vv "$PKG" 2>&1 | tee "$OUT/spctl.log"
    grep -q "source=Notarized Developer ID" "$OUT/spctl.log" || { echo "spctl didn't accept the package as notarized"; exit 1; }
fi
( cd "$OUT" && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256" && cp "$(basename "$PKG").sha256" SHA256SUMS )
cat "$OUT/$(basename "$PKG").sha256"
[ "$MODE" = "--test" ] || \
    echo "next: gh release create v$VERSION --prerelease \"$PKG\" \"$OUT/SHA256SUMS\""
