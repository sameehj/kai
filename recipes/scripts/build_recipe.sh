#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <recipe.yaml>"
  exit 1
fi

recipe="$1"
name=$(yq -r '.name' "$recipe")
version=$(yq -r '.version' "$recipe")
repo=$(yq -r '.upstream.repo' "$recipe")
ref=$(yq -r '.upstream.ref' "$recipe")

workdir="build/$name"
mkdir -p "$workdir"
cd "$workdir"

echo "[*] Building recipe: $name ($version)"
echo "[*] Upstream: $repo @ $ref"

# --- clone if missing ---
if [ ! -d "src" ]; then
  git clone "$repo" src
fi
cd src
git fetch --tags
git checkout "$ref"
commit=$(git rev-parse --short HEAD)
echo "[*] Checked out commit: $commit"

# --- run commands ---
while IFS= read -r cmd; do
  echo "[*] Running: $cmd"
  bash -c "$cmd"
done < <(yq -r '.build.commands[]' "../../../$recipe")

# --- copy outputs ---
dest="../../../dist/$name"
mkdir -p "$dest"
for path in $(yq -r '.outputs.programs[].path' "../../../$recipe"); do
  cp "$path" "$dest/"
done

echo "[✓] Build completed: $dest"
