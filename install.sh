#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Kai installer.
#
#   curl -fsSL https://raw.githubusercontent.com/sameehj/kai/master/install.sh | sh
#
# Installs the `kai` command (and on macOS the Kai menu-bar app), then writes
# a default policy. It does NOT change your agents' settings unless you ask:
#
#   curl -fsSL .../install.sh | KAI_HOOKS=all sh      # also wire up Claude Code + Cursor
#
# Options (environment variables):
#   KAI_VERSION  release tag (default: latest release; "master" builds the branch)
#   KAI_PREFIX   install prefix (default: /usr/local if writable, else ~/.local)
#   KAI_HOOKS    claude | cursor | all: run `kai install` for these agents
#   KAI_APP      0 to skip the macOS menu-bar app
#   KAI_REPO     GitHub repo (default: sameehj/kai)
#
# Prefers a prebuilt release binary (checked against SHA256SUMS). With no
# release for your platform it builds from source, which needs cc and make.
set -eu

REPO="${KAI_REPO:-sameehj/kai}"
VERSION="${KAI_VERSION:-latest}"
HOOKS="${KAI_HOOKS:-}"
WANT_APP="${KAI_APP:-1}"

say() { printf '\033[1mkai:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mkai:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || die "curl is required"
have tar || die "tar is required"

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux) OS=linux ;;
  *) die "unsupported OS: $(uname -s) (Kai supports macOS and Linux)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) ARCH=x86_64 ;;
  arm64 | aarch64) ARCH=arm64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac
# macOS release binaries are universal (Intel + Apple silicon).
[ "$OS" = darwin ] && PLAT=darwin-universal || PLAT="linux-$ARCH"

if [ -n "${KAI_PREFIX:-}" ]; then
  PREFIX="$KAI_PREFIX"
elif [ -w /usr/local/bin ] || { [ ! -e /usr/local/bin ] && [ -w /usr/local ]; }; then
  PREFIX=/usr/local
else
  PREFIX="$HOME/.local"
fi
BINDIR="$PREFIX/bin"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

sha256() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Download $1 to $2; quiet failure so callers can fall back.
fetch() { curl -fsSL --retry 2 -o "$2" "$1" 2>/dev/null; }

# Check a downloaded asset against the release's SHA256SUMS.
verify() {
  want=$(grep " \*\{0,1\}$1\$" "$TMP/SHA256SUMS" | cut -d' ' -f1)
  [ -n "$want" ] || die "$1 is not listed in SHA256SUMS"
  got=$(sha256 "$TMP/$1")
  [ "$want" = "$got" ] || die "checksum mismatch for $1 (download corrupted or tampered with)"
}

TAG=""
if [ "$VERSION" = latest ]; then
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) || true
elif [ "$VERSION" != master ]; then
  TAG="$VERSION"
fi

installed=0
APP_INSTALLED=0
if [ -n "$TAG" ]; then
  BASE="https://github.com/$REPO/releases/download/$TAG"
  ASSET="kai-$TAG-$PLAT.tar.gz"
  if fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" && fetch "$BASE/$ASSET" "$TMP/$ASSET"; then
    verify "$ASSET"
    tar -xzf "$TMP/$ASSET" -C "$TMP"
    mkdir -p "$BINDIR"
    install -m 0755 "$TMP/kai" "$BINDIR/kai"
    installed=1
    say "installed kai $TAG ($PLAT) to $BINDIR/kai"
  else
    say "no prebuilt $PLAT binary for $TAG; building from source"
  fi
fi

if [ "$installed" = 0 ]; then
  have make || die "building from source needs make (macOS: xcode-select --install)"
  have cc || have gcc || have clang || die "building from source needs a C compiler (macOS: xcode-select --install)"
  REF="${TAG:-master}"
  if [ -n "$TAG" ]; then SRC="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
  else SRC="https://github.com/$REPO/archive/refs/heads/master.tar.gz"; fi
  say "downloading source ($REF)"
  fetch "$SRC" "$TMP/src.tar.gz" || die "cannot download $SRC"
  mkdir "$TMP/src"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components=1
  say "building"
  make -C "$TMP/src" >/dev/null
  mkdir -p "$BINDIR"
  install -m 0755 "$TMP/src/kai" "$BINDIR/kai"
  say "installed kai ($REF, built from source) to $BINDIR/kai"
fi

KAI="$BINDIR/kai"
"$KAI" init

# macOS menu-bar app, shipped with releases.
if [ "$OS" = darwin ] && [ "$WANT_APP" != 0 ] && [ -n "$TAG" ]; then
  APPZIP="Kai-$TAG-macos.zip"
  if fetch "$BASE/$APPZIP" "$TMP/$APPZIP"; then
    verify "$APPZIP"
    if [ -w /Applications ]; then APPDIR=/Applications; else APPDIR="$HOME/Applications"; fi
    mkdir -p "$APPDIR"
    rm -rf "$APPDIR/Kai.app"
    (cd "$TMP" && unzip -q "$APPZIP")
    mv "$TMP/Kai.app" "$APPDIR/Kai.app"
    APP_INSTALLED=1
    say "installed the menu-bar app to $APPDIR/Kai.app"
    open "$APPDIR/Kai.app" 2>/dev/null || true
  fi
fi

if [ -n "$HOOKS" ]; then
  "$KAI" install "$HOOKS"
fi

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) say "add $BINDIR to your PATH, e.g.: echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc" ;;
esac

echo
"$KAI" doctor || true
echo
if [ -z "$HOOKS" ]; then
  say "next: turn on protection for your agents"
  echo "    kai install claude     # Claude Code"
  echo "    kai install cursor     # Cursor"
  if [ "$APP_INSTALLED" = 1 ]; then echo "    or use the Kai icon in the menu bar"; fi
fi
