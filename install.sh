#!/usr/bin/env bash
set -euo pipefail

OWNER="${OWNER:-sameehj}"
REPO="${REPO:-kai}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${KAI_VERSION:-}"
COMPONENTS=()

usage() {
  cat <<'EOF'
Kai installer

Usage: install.sh [--version <tag>] [--install-dir <path>] [--component <kaictl|kaid>]...

Environment overrides:
  OWNER            Override GitHub owner (default: sameehj)
  REPO             Override GitHub repository (default: kai)
  INSTALL_DIR      Installation directory (default: /usr/local/bin)
  KAI_VERSION      Target version/tag (default: latest release)

Options:
  --version <tag>       Install the specified Git tag (defaults to latest release)
  --install-dir <path>  Directory to place binaries in (defaults to /usr/local/bin)
  --component <name>    Component to install (kaictl or kaid). Repeatable. Defaults to both.
  --owner <owner>       Override GitHub owner (default: sameehj)
  --repo <repo>         Override GitHub repository (default: kai)
  -h, --help            Display this help message
EOF
}

while (($#)); do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --component)
      COMPONENTS+=("$2")
      shift 2
      ;;
    --owner)
      OWNER="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required dependency: $1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq

if [ ${#COMPONENTS[@]} -eq 0 ]; then
  COMPONENTS=(kaictl kaid)
fi

normalize_os() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux|darwin)
      echo "$os"
      ;;
    *)
      echo "Unsupported operating system: $os" >&2
      exit 1
      ;;
  esac
}

normalize_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    arm64|aarch64)
      echo "arm64"
      ;;
    *)
      echo "Unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac
}

fetch_version() {
  local url response
  if [ -n "$VERSION" ]; then
    url="https://api.github.com/repos/${OWNER}/${REPO}/releases/tags/${VERSION}"
  else
    url="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  fi
  response="$(curl -fsSL "$url")"
  if [ -z "$response" ]; then
    echo "Unable to fetch release metadata from $url" >&2
    exit 1
  fi
  echo "$response"
}

ensure_directory() {
  local dir="$1"
  if [ -d "$dir" ]; then
    return
  fi
  if mkdir -p "$dir" >/dev/null 2>&1; then
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$dir"
  else
    echo "Cannot create $dir. Please rerun with sudo or set INSTALL_DIR to a writable path." >&2
    exit 1
  fi
}

install_binary() {
  local src="$1" dest="$2"
  if mv "$src" "$dest" >/dev/null 2>&1; then
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo mv "$src" "$dest"
  else
    echo "Cannot move $src to $dest. Please rerun with sudo or choose a writable INSTALL_DIR." >&2
    exit 1
  fi
}

OS="$(normalize_os)"
ARCH="$(normalize_arch)"

release_json="$(fetch_version)"
VERSION="$(echo "$release_json" | jq -r '.tag_name')"

if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
  echo "Failed to determine release tag." >&2
  exit 1
fi

ensure_directory "$INSTALL_DIR"

for component in "${COMPONENTS[@]}"; do
  case "$component" in
    kaictl|kaid)
      ;;
    *)
      echo "Unsupported component: $component" >&2
      exit 1
      ;;
  esac

  asset="${component}-${OS}-${ARCH}"
  download_url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${asset}"
  tmp="$(mktemp)"

  echo "Downloading ${component} ${VERSION} (${OS}/${ARCH})..."
  if ! curl -fL "$download_url" -o "$tmp"; then
    echo "Failed to download ${download_url}. Ensure the release contains the asset." >&2
    rm -f "$tmp"
    exit 1
  fi

  chmod +x "$tmp"
  install_binary "$tmp" "${INSTALL_DIR}/${component}"
  echo "Installed ${INSTALL_DIR}/${component}"
done

echo "Kai ${VERSION} installation complete."
