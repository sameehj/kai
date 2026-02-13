#!/bin/sh
set -e

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
esac

case "$OS" in
    linux)
        INSTALL_DIR="/usr/local/bin"
        ;;
    darwin)
        INSTALL_DIR="/usr/local/bin"
        ;;
    *)
        echo "Unsupported OS: $OS"
        echo "On Windows, use: go install github.com/sameehj/kai/cmd/kai@latest"
        exit 1
        ;;
esac

echo "Installing KAI for $OS/$ARCH..."

if command -v go >/dev/null 2>&1; then
    echo "Building from source..."
    go install github.com/sameehj/kai/cmd/kai@latest
else
    echo "Go not found. Install Go from https://go.dev/dl/ and retry."
    exit 1
fi

echo ""
echo "KAI installed successfully."
echo ""
echo "Initialize workspace:  kai init"
echo "Start the gateway:     kai gateway"
echo "Start chat:            kai chat"
