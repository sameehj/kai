#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Regenerates the Chrome Web Store images in this folder from the extension's
# own code: popup.html/popup.js and content.js run in headless Chrome with a
# stand-in chrome API; the held message's scan result and redacted text come
# from the real `kai` (build it first: make kai). The sample key is AWS's
# documentation example key, assembled here.
set -eu
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
export KAI_STORE_WORK="$(mktemp -d /tmp/kai-store.XXXXXX)"
C="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
K1=AKIA; K2=IOSFODNN7EXAMPLE
printf 'Can you fix this deploy script? It fails on the upload step.\nexport AWS_ACCESS_KEY_ID=%s%s\naws s3 cp build/ s3://acme-releases/ --recursive' "$K1" "$K2" > "$KAI_STORE_WORK/msg.txt"
"$ROOT/kai" redact < "$KAI_STORE_WORK/msg.txt" > "$KAI_STORE_WORK/cleaned.txt" || true   # non-zero when it redacted
grep -q "REDACTED by Kai" "$KAI_STORE_WORK/cleaned.txt" || { echo "kai redact didn't redact the sample key"; exit 1; }
python3 -I "$D/build_stage.py" >/dev/null
S="$KAI_STORE_WORK/stage"; P="$KAI_STORE_WORK/profile"
shot() {
    "$C" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --user-data-dir="$P" \
         --no-first-run --allow-file-access-from-files --virtual-time-budget=5000 \
         --window-size="$3" --screenshot="$D/$2" "file://$S/$1" >/dev/null 2>&1 || true   # exits 2 even on success
    size=$(sips -g pixelWidth -g pixelHeight "$D/$2" 2>/dev/null | awk '/pixel/ {printf "%s%s", sep, $2; sep=","}')
    [ "$size" = "$3" ] || { echo "$2: expected $3, got ${size:-nothing}"; exit 1; }
    echo "$2 ($size)"
}
shot shot1-held.html    kai-store-1-held-message.png  1280,800
shot shot2-popup.html   kai-store-2-popup.png         1280,800
shot shot3-offline.html kai-store-3-not-connected.png 1280,800
shot tile-440x280.html  kai-store-promo-440x280.png   440,280
rm -rf "$KAI_STORE_WORK"
