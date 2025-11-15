#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_OWNER_CANDIDATES=("kai-project" "sameehj")
OWNER="${OWNER:-}"
REPO="${REPO:-kai}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${KAI_VERSION:-}"
SOURCE_DIR="${SOURCE_DIR:-}"
COMPONENTS=()
OWNER_CANDIDATES=()
RESOLVED_OWNER=""
SOURCE_BUILD_DIR=""
LOCAL_SOURCE_DIR=""

strip_version_part() {
  local part="$1"
  part="${part%%[^0-9]*}"
  if [ -z "$part" ]; then
    part="0"
  fi
  echo "$part"
}

semver_key() {
  local version="${1#go}"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$version"
  major="$(strip_version_part "${major:-0}")"
  minor="$(strip_version_part "${minor:-0}")"
  patch="$(strip_version_part "${patch:-0}")"
  printf "%04d%04d%04d" "$major" "$minor" "$patch"
}

version_lt() {
  local a_key b_key
  a_key="$(semver_key "$1")"
  b_key="$(semver_key "$2")"
  [[ "$a_key" < "$b_key" ]]
}

get_installed_go_version() {
  local ver=""
  if ver="$(go env GOVERSION 2>/dev/null)"; then
    ver="${ver#go}"
  else
    ver="$(go version 2>/dev/null | awk '{print $3}')"
    ver="${ver#go}"
  fi
  echo "$ver"
}

cleanup_source_dir() {
  if [ -n "$SOURCE_BUILD_DIR" ] && [ -d "$SOURCE_BUILD_DIR" ]; then
    rm -rf "$SOURCE_BUILD_DIR"
  fi
}

trap cleanup_source_dir EXIT

usage() {
  cat <<'EOF'
Kai installer

Usage: install.sh [--version <tag>] [--install-dir <path>] [--component <kaictl|kaid>]...

Environment overrides:
  OWNER            Override GitHub owner (default: kai-project, fallback to sameehj)
  REPO             Override GitHub repository (default: kai)
  INSTALL_DIR      Installation directory (default: /usr/local/bin)
  KAI_VERSION      Target version/tag (default: latest release)
  SOURCE_DIR       Use an existing source directory instead of cloning

Options:
  --version <tag>       Install the specified Git tag (defaults to latest release)
  --install-dir <path>  Directory to place binaries in (defaults to /usr/local/bin)
  --component <name>    Component to install (kaictl or kaid). Repeatable. Defaults to both.
  --owner <owner>       Override GitHub owner (default: kai-project, fallback to sameehj)
  --repo <repo>         Override GitHub repository (default: kai)
  --source-dir <path>   Build directly from an existing checkout
  -h, --help            Display this help message

If no GitHub releases are available (or assets are missing), the installer clones
the repository and builds the binaries locally. Source builds require git and go.
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
    --source-dir)
      SOURCE_DIR="$2"
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

fetch_version_for_owner() {
  local owner="$1" url response
  if [ -n "$VERSION" ]; then
    url="https://api.github.com/repos/${owner}/${REPO}/releases/tags/${VERSION}"
  else
    url="https://api.github.com/repos/${owner}/${REPO}/releases/latest"
  fi
  if ! response="$(curl -fsSL "$url" 2>/dev/null)"; then
    return 1
  fi
  if [ -z "$response" ]; then
    return 1
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

install_from_release() {
  local release_json="$1"
  VERSION="$(echo "$release_json" | jq -r '.tag_name')"

  if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
    echo "Failed to determine release tag from metadata." >&2
    return 1
  fi

  for component in "${COMPONENTS[@]}"; do
    case "$component" in
      kaictl|kaid)
        ;;
      *)
        echo "Unsupported component: $component" >&2
        return 1
        ;;
    esac

    asset="${component}-${OS}-${ARCH}"
    download_url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${asset}"
    tmp="$(mktemp)"

    echo "Downloading ${component} ${VERSION} (${OS}/${ARCH})..."
    if ! curl -fL "$download_url" -o "$tmp"; then
      echo "Failed to download ${download_url}. Ensure the release contains the asset." >&2
      rm -f "$tmp"
      return 1
    fi

    chmod +x "$tmp"
    install_binary "$tmp" "${INSTALL_DIR}/${component}"
    echo "Installed ${INSTALL_DIR}/${component}"
  done

  echo "Kai ${VERSION} installation complete (release build)."
  return 0
}

ensure_go_version_for_module() {
  local src_dir="$1"
  local mod_file="${src_dir}/go.mod"

  if [ ! -f "$mod_file" ]; then
    echo "Missing go.mod in ${src_dir}. Cannot build Go components." >&2
    return 1
  fi

  local installed_go
  installed_go="$(get_installed_go_version)"
  if [ -z "$installed_go" ]; then
    echo "Unable to detect installed Go version. Ensure Go is installed and available in PATH." >&2
    return 1
  fi

  local required_go=""
  required_go="$(awk '/^go[[:space:]]+[0-9]/{print $2; exit}' "$mod_file" 2>/dev/null || true)"

  if [ -n "$required_go" ] && version_lt "$installed_go" "$required_go"; then
    echo "Go ${required_go} or newer is required by ${mod_file}, but Go ${installed_go} is installed. Upgrade Go or set GOTOOLCHAIN to a newer release." >&2
    return 1
  fi

  if grep -q '^toolchain[[:space:]]\+' "$mod_file"; then
    if version_lt "$installed_go" "1.21"; then
      echo "The toolchain directive in ${mod_file} requires Go 1.21 or newer. Go ${installed_go} is installed. Upgrade Go to continue." >&2
      return 1
    fi
  fi

  return 0
}

build_components_from_dir() {
  local src_dir="$1"
  local label="$2"

  if [ ! -d "$src_dir" ]; then
    echo "Source directory ${src_dir} does not exist." >&2
    return 1
  fi

  require_cmd go
  if ! ensure_go_version_for_module "$src_dir"; then
    return 1
  fi

  for component in "${COMPONENTS[@]}"; do
    case "$component" in
      kaictl|kaid)
        ;;
      *)
        echo "Unsupported component: $component" >&2
        return 1
        ;;
    esac

    if [ ! -d "${src_dir}/cmd/${component}" ]; then
      echo "Component ${component} was requested but ${src_dir}/cmd/${component} is missing." >&2
      return 1
    fi

    local tmp_bin
    tmp_bin="$(mktemp)"
    echo "Building ${component} from ${label} (${OS}/${ARCH})..."
    if ! (cd "$src_dir" && GOOS="$OS" GOARCH="$ARCH" go build -o "$tmp_bin" "./cmd/${component}"); then
      echo "Failed to build ${component}. Ensure Go toolchain is installed." >&2
      rm -f "$tmp_bin"
      return 1
    fi

    chmod +x "$tmp_bin"
    install_binary "$tmp_bin" "${INSTALL_DIR}/${component}"
    echo "Installed ${INSTALL_DIR}/${component} (${label})"
  done

  return 0
}

install_from_source() {
  require_cmd git
  SOURCE_BUILD_DIR="$(mktemp -d)"
  local repo_dir="${SOURCE_BUILD_DIR}/src"
  local repo_url="https://github.com/${OWNER}/${REPO}.git"

  echo "Cloning ${repo_url}..."
  if ! git clone "$repo_url" "$repo_dir" >/dev/null 2>&1; then
    echo "Failed to clone ${repo_url}. Set OWNER/REPO to a reachable repository." >&2
    return 1
  fi

  if [ -n "$VERSION" ]; then
    echo "Checking out ${VERSION}..."
    if ! git -C "$repo_dir" checkout "$VERSION" >/dev/null 2>&1; then
      echo "Failed to checkout ${VERSION}. Ensure the ref exists in ${repo_url}." >&2
      return 1
    fi
  fi

  if ! build_components_from_dir "$repo_dir" "source build"; then
    return 1
  fi

  echo "Kai installation complete (built from source)."
  return 0
}

resolve_local_source_dir() {
  if [ -n "$LOCAL_SOURCE_DIR" ]; then
    return 0
  fi

  local candidate=""

  if [ -n "$SOURCE_DIR" ]; then
    if [ ! -d "$SOURCE_DIR" ]; then
      echo "SOURCE_DIR ${SOURCE_DIR} does not exist." >&2
      exit 1
    fi
    if ! candidate="$(cd "$SOURCE_DIR" && pwd)"; then
      echo "Failed to resolve SOURCE_DIR ${SOURCE_DIR}." >&2
      exit 1
    fi
  else
    if command -v git >/dev/null 2>&1; then
      candidate="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [ -z "$candidate" ] && [ -f "${SCRIPT_DIR}/go.mod" ]; then
      candidate="$SCRIPT_DIR"
    fi
  fi

  if [ -z "$candidate" ]; then
    return 1
  fi

  if [ ! -f "${candidate}/go.mod" ]; then
    if [ -n "$SOURCE_DIR" ]; then
      echo "SOURCE_DIR ${candidate} is missing go.mod. Provide a kai checkout or omit --source-dir." >&2
      exit 1
    fi
    return 1
  fi

  LOCAL_SOURCE_DIR="$candidate"
  return 0
}

verify_local_source_version() {
  local dir="$1"

  if [ -z "$VERSION" ]; then
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "Cannot verify requested version ${VERSION} without git. Install git or omit --version." >&2
    return 1
  fi

  if ! git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Source directory ${dir} is not a git repository; cannot ensure version ${VERSION}." >&2
    return 1
  fi

  local requested_commit current_commit current_short
  if ! requested_commit="$(git -C "$dir" rev-parse --verify "${VERSION}^{commit}" 2>/dev/null)"; then
    echo "Local repository at ${dir} does not contain ref ${VERSION}. Check out the desired version and retry." >&2
    return 1
  fi

  current_commit="$(git -C "$dir" rev-parse HEAD)"
  if [ "$current_commit" != "$requested_commit" ]; then
    current_short="$(git -C "$dir" rev-parse --short HEAD)"
    echo "Local repository HEAD (${current_short}) does not match requested version ${VERSION}. Checkout that ref before installing." >&2
    return 1
  fi

  return 0
}

install_from_local_source() {
  local dir="$1"

  echo "Using local source at ${dir}..."
  if ! verify_local_source_version "$dir"; then
    return 1
  fi

  if ! build_components_from_dir "$dir" "local source"; then
    return 1
  fi

  echo "Kai installation complete (local source build)."
  return 0
}

OS="$(normalize_os)"
ARCH="$(normalize_arch)"

if [ -n "$OWNER" ]; then
  OWNER_CANDIDATES=("$OWNER")
else
  OWNER_CANDIDATES=("${DEFAULT_OWNER_CANDIDATES[@]}")
fi

release_json=""
for candidate in "${OWNER_CANDIDATES[@]}"; do
  if release_json="$(fetch_version_for_owner "$candidate")"; then
    RESOLVED_OWNER="$candidate"
    break
  fi
done

if [ -n "$RESOLVED_OWNER" ]; then
  OWNER="$RESOLVED_OWNER"
elif [ -z "$OWNER" ]; then
  OWNER="${OWNER_CANDIDATES[0]}"
fi

ensure_directory "$INSTALL_DIR"

if [ -n "$release_json" ]; then
  if install_from_release "$release_json"; then
    exit 0
  fi
  echo "Falling back to source build because release installation failed." >&2
else
  echo "No GitHub releases available for ${OWNER}/${REPO}. Building from source..." >&2
fi

if resolve_local_source_dir; then
  if install_from_local_source "$LOCAL_SOURCE_DIR"; then
    exit 0
  fi
  echo "Local source build failed. Attempting to clone ${OWNER}/${REPO}..." >&2
fi

if install_from_source; then
  exit 0
fi

echo "Kai installation failed." >&2
exit 1
