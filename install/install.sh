#!/usr/bin/env bash
set -euo pipefail

REPO="github.com/kai-ai/kai"
BIN_NAME="kai"
INSTALL_DIR="${HOME}/.kai/bin"
AUTOSTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --autostart)
      AUTOSTART=1
      shift
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$INSTALL_DIR"
mkdir -p "${HOME}/.kai"

OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v go >/dev/null 2>&1; then
  GOBIN="$INSTALL_DIR" go install "${REPO}/cmd/kai@latest"
else
  URL="https://${REPO}/releases/latest/download/kai-${OS}-${ARCH}.tar.gz"
  curl -fsSL "$URL" -o "$TMP/kai.tgz"
  tar -xzf "$TMP/kai.tgz" -C "$TMP"
  install -m 0755 "$TMP/${BIN_NAME}" "$INSTALL_DIR/${BIN_NAME}"
fi

if ! echo ":$PATH:" | grep -q ":${HOME}/.kai/bin:"; then
  SHELL_RC="${HOME}/.bashrc"
  if [[ "${SHELL:-}" == *"zsh"* ]]; then
    SHELL_RC="${HOME}/.zshrc"
  fi
  echo 'export PATH="$HOME/.kai/bin:$PATH"' >> "$SHELL_RC"
fi

"$INSTALL_DIR/$BIN_NAME" daemon start

if [[ "$AUTOSTART" -eq 1 ]]; then
  if [[ "$OS" == "darwin" ]]; then
    PLIST="${HOME}/Library/LaunchAgents/ai.kai.daemon.plist"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.kai.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/${BIN_NAME}</string>
    <string>daemon</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load "$PLIST"
  elif [[ "$OS" == "linux" ]]; then
    UNIT_DIR="${HOME}/.config/systemd/user"
    UNIT_PATH="${UNIT_DIR}/kai.service"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=KAI daemon
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/${BIN_NAME} daemon run
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now kai.service
  fi
fi

echo "installed: ${INSTALL_DIR}/${BIN_NAME}"
echo "run: kai daemon status"
