#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <recipe.yaml>"
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

recipe_path="$1"
if [ ! -f "$recipe_path" ]; then
  recipe_path="${repo_root}/${recipe_path}"
fi

if [ ! -f "$recipe_path" ]; then
  echo "Recipe not found: $1" >&2
  exit 1
fi

name=$(yq -r '.name' "$recipe_path")
version=$(yq -r '.version' "$recipe_path")
repo=$(yq -r '.upstream.repo' "$recipe_path")
ref=$(yq -r '.upstream.ref' "$recipe_path")
image=$(yq -r '.builder.image // "ghcr.io/kai/build-ebpf:llvm16-ubuntu22.04"' "$recipe_path")
license=$(yq -r '.license // ""' "$recipe_path")
if [ "$license" = "null" ]; then
  license=""
fi

workdir="${repo_root}/recipes/build/${name}"
mkdir -p "$workdir"
cd "$workdir"

echo "[*] Building recipe: ${name} (${version})"
echo "[*] Upstream: ${repo} @ ${ref}"

if [ ! -d "src" ]; then
  git clone "$repo" src
fi

cd src
git fetch --tags
git checkout "$ref"
commit=$(git rev-parse --short HEAD)
echo "[*] Checked out commit: ${commit}"

commands_file="$(mktemp)"
yq -r '.build.commands[]' "$recipe_path" >"$commands_file"

while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  echo "[*] Running in container: $cmd"
  docker run --rm -v "$(pwd):/src" -w /src "$image" bash -lc "$cmd"
done <"$commands_file"

rm -f "$commands_file"

dest="${repo_root}/recipes/dist/${name}/${version}"
mkdir -p "$dest"

program_files=()
while IFS= read -r output_path; do
  [ -z "$output_path" ] && continue
  if [ ! -f "$output_path" ]; then
    echo "Expected output not found: $output_path" >&2
    exit 1
  fi
  base=$(basename "$output_path")
  cp "$output_path" "$dest/$base"
  program_files+=("$base")
done < <(yq -r '.outputs.programs[].path' "$recipe_path")

manifest="${dest}/manifest.yaml"
{
  echo "apiVersion: kai.package/v1"
  echo "kind: Package"
  echo "metadata:"
  echo "  name: $name"
  echo "  version: $version"
  if [ -n "$license" ]; then
    echo "  license: $license"
  fi
  echo "upstream:"
  echo "  repo: $repo"
  echo "  ref: $ref"
  echo "build:"
  echo "  output:"
  for file in "${program_files[@]}"; do
    echo "    - $file"
  done
  echo "artifacts:"
  echo "  built_at: \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
} >"$manifest"

cp "$recipe_path" "${dest}/recipe.yaml"

echo "[✓] Build completed: ${dest}"
