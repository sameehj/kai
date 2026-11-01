#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Step 7: the Developer ID release signing (scripts/release/sign-app.sh).
# What can be checked without Apple credentials: the release entitlements use
# the system-extension form of the content-filter entitlement, the checks fail
# on a bundle that isn't Developer ID signed, and signing refuses to start
# without its identities and profiles. The signed, notarized build itself is
# checked by the same `check` mode inside `make release`.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/scripts/release/sign-app.sh"
T="$(mktemp -d)"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
command -v codesign >/dev/null 2>&1 || { echo "sign tests: skipped (no codesign)"; exit 0; }

echo "release signing (Step 7)"
sh "$S" entitlements "$T/ent" ABCDE12345 >/dev/null 2>&1 || fail "entitlements mode runs"
for f in app ext; do
    e="$T/ent/$f.entitlements"
    [ -s "$e" ] || { fail "$f entitlements written"; continue; }
    plutil -lint "$e" >/dev/null 2>&1 && pass "$f entitlements are a valid plist" || fail "$f entitlements plist"
    grep -q "<string>content-filter-provider-systemextension</string>" "$e" \
        && pass "$f: content filter in the system-extension form" || fail "$f lacks content-filter-provider-systemextension"
    grep -q "<string>content-filter-provider</string>" "$e" \
        && fail "$f still has the bare content-filter-provider (rejected for Developer ID)" || pass "$f: no bare content-filter-provider"
    grep -q "<string>ABCDE12345.io.github.sameehj.kai</string>" "$e" \
        && pass "$f: app group with the team prefix expanded" || fail "$f app group not expanded"
    grep -q 'TeamIdentifierPrefix' "$e" && fail "$f has an unexpanded \$(TeamIdentifierPrefix)" || true
done
grep -q "com.apple.developer.system-extension.install" "$T/ent/app.entitlements" \
    && pass "app may install the system extension" || fail "app lacks system-extension.install"

# the release entitlements carry exactly the keys project.yml gives each target
Y="$ROOT/app/macos/project.yml"
for k in com.apple.developer.networking.networkextension com.apple.security.application-groups \
         com.apple.developer.system-extension.install; do
    n=$(grep -c "^ *$k:" "$Y")
    m=$(cat "$T/ent/app.entitlements" "$T/ent/ext.entitlements" | grep -c "<key>$k</key>")
    [ "$n" = "$m" ] && pass "$k: in project.yml and the release entitlements alike ($n)" \
        || fail "$k: project.yml has it $n times, the release entitlements $m"
done

# signing refuses without its inputs
out=$(env -u KAI_DEVID_APP -u KAI_TEAM sh "$S" sign "$T/none.app" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q "KAI_DEVID_APP" \
    && pass "sign refuses without KAI_DEVID_APP / KAI_TEAM / profiles (exit 2, says what's missing)" \
    || fail "sign without identities: exit $rc, $out"

out=$(KAI_TEAM=ZZZZZ99999 KAI_DEVID_APP=x KAI_APP_PROFILE=x KAI_EXT_PROFILE=x sh "$S" sign "$T/none.app" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q "KAI_APP_GROUP" \
    && pass "sign refuses a team other than the one compiled into KAI_APP_GROUP" || fail "sign with another team: exit $rc, $out"

# check fails on a bundle that isn't Developer ID signed and notarized
A="$T/Fake.app"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Library/SystemExtensions/x.systemextension/Contents/MacOS"
printf 'int main(void){return 0;}\n' > "$T/m.c"
if cc -o "$A/Contents/MacOS/Kai" "$T/m.c" 2>/dev/null; then
    cp "$A/Contents/MacOS/Kai" "$A/Contents/Library/SystemExtensions/x.systemextension/Contents/MacOS/x"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>x</string><key>CFBundleExecutable</key><string>Kai</string></dict></plist>\n' > "$A/Contents/Info.plist"
    codesign --force --sign - "$A" >/dev/null 2>&1
    out=$(KAI_TEAM=ABCDE12345 sh "$S" check "$A" 2>&1); rc=$?
    [ $rc -ne 0 ] && pass "check fails on an ad-hoc signed bundle" || fail "check passed an ad-hoc bundle"
    echo "$out" | grep -q "FAIL" && pass "...and names the failed check" || fail "check gave no FAIL line: $out"
    echo "$out" | grep -q "FAIL.*storage extension" && fail "check reported a storage extension that isn't there" || pass "no storage extension: not flagged"
    # Files isn't in this release: a storage extension inside the app is a FAIL
    mkdir -p "$A/Contents/Library/SystemExtensions/io.github.sameehj.kai.storage.systemextension"
    out=$(KAI_TEAM=ABCDE12345 sh "$S" check "$A" 2>&1)
    echo "$out" | grep -q "FAIL.*storage extension" && pass "check fails when the storage extension is inside the app" \
        || fail "check didn't flag the storage extension"
else
    echo "  skip no cc for the fake bundle"
fi

rm -rf "$T"
[ $fails -eq 0 ] && echo "sign tests: all passed" || echo "sign tests: $fails failed"
exit $fails
