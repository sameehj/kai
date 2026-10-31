#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Step 7: Developer ID signing of Kai.app and its network system extension.
#
#   sign-app.sh entitlements <outdir> <team>   release entitlements (tests use this)
#   sign-app.sh sign <Kai.app>                 embed profiles, sign inside out
#   sign-app.sh check <Kai.app> [--notarized]  every check; exit 1 on any FAIL
#
# sign needs:
#   KAI_TEAM          Apple team ID (e.g. KD446VDTM2)
#   KAI_DEVID_APP     "Developer ID Application: Name (TEAMID)"
#   KAI_APP_PROFILE   Developer ID provisioning profile for io.github.sameehj.kai
#   KAI_EXT_PROFILE   Developer ID provisioning profile for io.github.sameehj.kai.network
#
# A Developer ID system extension must hold the content filter in its
# system-extension form (content-filter-provider-systemextension); the bare
# content-filter-provider is for development signing only. The checked-in
# entitlement files keep the development form for `make app-dev`; the release
# form is generated from them here, so the two can't drift apart.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT_ID=io.github.sameehj.kai.network
FAILS=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }

release_entitlements() {   # <src> <dst> <team>
    sed -e 's|<string>content-filter-provider</string>|<string>content-filter-provider-systemextension</string>|' \
        -e "s|\$(TeamIdentifierPrefix)|$3.|g" "$1" > "$2"
    plutil -lint "$2" >/dev/null || { echo "bad entitlements: $2"; exit 1; }
}

# The team compiled into libkai's app group (include/kai.h KAI_APP_GROUP):
# the CLI reads the extension's heartbeat from that container, so a release
# signed by another team would never be seen as running.
compiled_team() { sed -n 's/^#define KAI_APP_GROUP "\([A-Z0-9]*\)\..*/\1/p' "$ROOT/include/kai.h"; }

ext_path() { echo "$1/Contents/Library/SystemExtensions/$EXT_ID.systemextension"; }

profile_plist() {   # <profile> <out>: the decoded profile
    security cms -D -i "$1" > "$2" 2>/dev/null
}

cmd="${1:-}"; shift || true
case "$cmd" in
entitlements)
    out="${1:?outdir}"; team="${2:?team}"
    mkdir -p "$out"
    release_entitlements "$ROOT/app/macos/Sources/Kai.entitlements" "$out/app.entitlements" "$team"
    release_entitlements "$ROOT/app/macos/Network/Network.entitlements" "$out/ext.entitlements" "$team"
    echo "$out/app.entitlements $out/ext.entitlements"
    ;;

sign)
    app="${1:?Kai.app}"
    missing=""
    for v in KAI_TEAM KAI_DEVID_APP KAI_APP_PROFILE KAI_EXT_PROFILE; do
        eval "[ -n \"\${$v:-}\" ]" || missing="$missing $v"
    done
    [ -z "$missing" ] || { echo "sign needs:$missing (see the top of $0)"; exit 2; }
    [ "$KAI_TEAM" = "$(compiled_team)" ] || {
        echo "KAI_TEAM $KAI_TEAM isn't the team in include/kai.h KAI_APP_GROUP ($(compiled_team))"; exit 2; }
    [ -f "$KAI_APP_PROFILE" ] && [ -f "$KAI_EXT_PROFILE" ] || { echo "a provisioning profile file is missing"; exit 2; }
    [ -d "$app" ] || { echo "no app at $app"; exit 2; }
    ext="$(ext_path "$app")"
    [ -d "$ext" ] || { echo "no network extension at $ext"; exit 1; }
    set -e
    work="$(mktemp -d)"
    sh "$0" entitlements "$work" "$KAI_TEAM" >/dev/null
    cp "$KAI_EXT_PROFILE" "$ext/Contents/embedded.provisionprofile"
    cp "$KAI_APP_PROFILE" "$app/Contents/embedded.provisionprofile"
    sign() { codesign --force --options runtime --timestamp --sign "$KAI_DEVID_APP" "$@"; }
    # inside out: the bundled CLI, the extension, then the app
    sign "$app/Contents/Resources/kai"
    sign --entitlements "$work/ext.entitlements" "$ext"
    sign --entitlements "$work/app.entitlements" "$app"
    rm -rf "$work"
    echo "signed $app"
    ;;

check)
    app="${1:?Kai.app}"; notarized="${2:-}"
    team="${KAI_TEAM:-}"
    [ -n "$team" ] || { echo "check needs KAI_TEAM"; exit 2; }
    ext="$(ext_path "$app")"
    w="$(mktemp -d)"
    echo "release checks: $app"
    [ "$team" = "$(compiled_team)" ] && ok "team $team matches KAI_APP_GROUP" \
        || bad "team $team isn't the KAI_APP_GROUP team $(compiled_team)"
    [ -d "$ext" ] && ok "network extension present" || bad "no network extension at $ext"

    # entitlements actually signed into each bundle
    for b in "$app" "$ext"; do
        n=$(basename "$b")
        codesign -d --entitlements :- "$b" > "$w/e.plist" 2>/dev/null || : > "$w/e.plist"
        grep -q "<string>content-filter-provider-systemextension</string>" "$w/e.plist" \
            && ok "$n: content-filter-provider-systemextension" || bad "$n: no content-filter-provider-systemextension entitlement"
        grep -q "<string>content-filter-provider</string>" "$w/e.plist" \
            && bad "$n: bare content-filter-provider (development form)" || true
        grep -q "<string>$team.io.github.sameehj.kai</string>" "$w/e.plist" \
            && ok "$n: app group $team.io.github.sameehj.kai" || bad "$n: app group not $team.io.github.sameehj.kai"
        codesign -dvv "$b" > "$w/d.txt" 2>&1 || true
        grep -q "^Authority=Developer ID Application:" "$w/d.txt" && ok "$n: Developer ID Application" \
            || bad "$n: not signed with Developer ID Application"
        grep -q "^TeamIdentifier=$team$" "$w/d.txt" && ok "$n: team $team" || bad "$n: team isn't $team"
        grep -q "flags=.*runtime" "$w/d.txt" && ok "$n: hardened runtime" || bad "$n: no hardened runtime"
        grep -q "^Timestamp=" "$w/d.txt" && ok "$n: secure timestamp" || bad "$n: no secure timestamp"
        if [ -f "$b/Contents/embedded.provisionprofile" ] && profile_plist "$b/Contents/embedded.provisionprofile" "$w/p.plist"; then
            grep -q "content-filter-provider-systemextension" "$w/p.plist" \
                && ok "$n: profile allows the system-extension content filter" || bad "$n: profile lacks content-filter-provider-systemextension"
        else
            bad "$n: no embedded Developer ID provisioning profile"
        fi
    done
    codesign -d --entitlements :- "$app" 2>/dev/null | grep -q "com.apple.developer.system-extension.install" \
        && ok "app may install the system extension" || bad "app lacks system-extension.install"
    mach=$(/usr/libexec/PlistBuddy -c "Print :NetworkExtension:NEMachServiceName" "$ext/Contents/Info.plist" 2>/dev/null || true)
    case "$mach" in "$team".*) ok "NEMachServiceName $mach" ;; *) bad "NEMachServiceName '$mach' doesn't start with $team." ;; esac

    # every executable, then the whole bundle
    find "$app" -type f -perm -u+x > "$w/x.txt"
    n=0
    while IFS= read -r f; do
        file -b "$f" | grep -q "Mach-O" || continue
        n=$((n + 1))
        codesign --verify --strict "$f" 2>"$w/v.txt" && ok "codesign --verify --strict ${f#$app/}" \
            || bad "codesign --verify --strict ${f#$app/}: $(head -1 "$w/v.txt")"
    done < "$w/x.txt"
    [ $n -gt 0 ] || bad "no executables found in $app"
    codesign --verify --deep --strict "$app" 2>"$w/v.txt" && ok "codesign --verify --deep --strict (whole app)" \
        || bad "codesign --verify --deep --strict: $(head -1 "$w/v.txt")"
    if [ "$notarized" = "--notarized" ]; then
        xcrun stapler validate "$app" >/dev/null 2>&1 && ok "notarization ticket stapled" || bad "no stapled ticket"
        spctl --assess --type execute -vv "$app" > "$w/s.txt" 2>&1
        grep -q "source=Notarized Developer ID" "$w/s.txt" && ok "spctl: accepted, Notarized Developer ID" \
            || bad "spctl --assess: $(tr '\n' ' ' < "$w/s.txt")"
    else
        spctl --assess --type execute -vv "$app" > "$w/s.txt" 2>&1 \
            && ok "spctl --assess (before notarization)" || echo "  note spctl before notarization: $(tr '\n' ' ' < "$w/s.txt")"
    fi
    rm -rf "$w"
    [ $FAILS -eq 0 ] && echo "release checks: all passed" || echo "release checks: $FAILS FAILED"
    [ $FAILS -eq 0 ]
    ;;

*)
    sed -n '4,13p' "$0"; exit 2 ;;
esac
