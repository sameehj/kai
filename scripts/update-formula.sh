#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Point Formula/kai.rb at a released tag: scripts/update-formula.sh v0.1.0
set -eu
TAG="${1:?usage: $0 <tag>}"
URL="https://github.com/sameehj/kai/archive/refs/tags/$TAG.tar.gz"
SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
F="$(dirname "$0")/../Formula/kai.rb"
# drop any previous url/sha256, then add them after the license line
sed -i.bak -e '/^  url "/d' -e '/^  sha256 "/d' "$F"
sed -i.bak "s|^  license \"GPL-3.0-only\"|  url \"$URL\"\\
  sha256 \"$SHA\"\\
  license \"GPL-3.0-only\"|" "$F"
rm -f "$F.bak"
echo "Formula/kai.rb -> $TAG ($SHA)"
