#!/bin/bash
set -euo pipefail

REPO="sameehj/kai"
BINARY="kai"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Installing Kai for $OS/$ARCH..."

VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | cut -d'"' -f4)

URL="https://github.com/$REPO/releases/download/$VERSION/kai_${OS}_${ARCH}.tar.gz"

TMPDIR=$(mktemp -d)
curl -fsSL "$URL" -o "$TMPDIR/kai.tar.gz"
tar xzf "$TMPDIR/kai.tar.gz" -C "$TMPDIR"

if [ -w /usr/local/bin ]; then
    mv "$TMPDIR/$BINARY" /usr/local/bin/$BINARY
else
    sudo mv "$TMPDIR/$BINARY" /usr/local/bin/$BINARY
fi

rm -rf "$TMPDIR"

echo "Kai $VERSION installed."
echo "Run 'kai' to get started."
