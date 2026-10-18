# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Build the Chrome Web Store upload: build/kai-chrome-<version>.zip.

usage: python3 scripts/package-chrome.py

Differences from the unpacked extension in integrations/browser:
  - no "key": the store assigns the published extension its own ID
    (put that ID in KAI_STORE_EXTENSION_ID, src/internal.h)
  - no local test page (kai-browser-test.html) and no file:// match, which
    the store would flag as an unneeded permission
Fails if the result asks for anything beyond nativeMessaging and storage.
"""
import json
import os
import sys
import zipfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "integrations", "browser")
manifest = json.load(open(os.path.join(src, "manifest.json"), encoding="utf-8"))

manifest.pop("key", None)
for cs in manifest.get("content_scripts", []):
    cs["matches"] = [m for m in cs["matches"] if not m.startswith("file:")]
if set(manifest.get("permissions", [])) - {"nativeMessaging", "storage"}:
    sys.exit(f"unexpected permissions: {manifest['permissions']}")
if manifest.get("host_permissions"):
    sys.exit("unexpected host_permissions")

skip = {"manifest.json", "kai-browser-test.html", ".DS_Store"}
out_dir = os.path.join(root, "build")
os.makedirs(out_dir, exist_ok=True)
out = os.path.join(out_dir, f"kai-chrome-{manifest['version']}.zip")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
    for dirpath, _, files in os.walk(src):
        for f in sorted(files):
            if f in skip:
                continue
            full = os.path.join(dirpath, f)
            z.write(full, os.path.relpath(full, src))
print(out)
with zipfile.ZipFile(out) as z:
    for n in z.namelist():
        print("  ", n)
