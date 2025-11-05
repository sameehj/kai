# ----------- Kai Runtime Makefile -----------

BINDIR ?= $(PWD)/dist
GO     ?= go
PREFIX ?= /usr/local
CONFIGDIR ?= /etc/kai
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "v0.0.0")

# Default target
all: build

# Compile binaries
build:
	@echo "[*] Building kai runtime..."
	$(GO) build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BINDIR)/kaid ./cmd/kaid
	$(GO) build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BINDIR)/kaictl ./cmd/kaictl
	@echo "[✓] Binaries in $(BINDIR)"

# Run local tests
test:
	GOCACHE=$(PWD)/.gocache $(GO) test ./...

# Install to system
install:
	@echo "[*] Installing binaries to $(PREFIX)/bin"
	install -d $(PREFIX)/bin
	install -m 0755 $(BINDIR)/kaid $(PREFIX)/bin/kaid
	install -m 0755 $(BINDIR)/kaictl $(PREFIX)/bin/kaictl

	@echo "[*] Installing configs to $(CONFIGDIR)"
	install -d $(CONFIGDIR)
	install -m 0644 configs/kai-config.yaml $(CONFIGDIR)/config.yaml
	install -m 0644 configs/policy.yaml $(CONFIGDIR)/policy.yaml

	@echo "[✓] Kai installed at $(PREFIX)/bin"

# Clean up build artifacts
clean:
	rm -rf $(BINDIR) .gocache

# Package into tar.gz
package: build
	tar -czf kai-$(VERSION).tar.gz -C $(BINDIR) kaid kaictl
	@echo "[✓] Created kai-$(VERSION).tar.gz"

.PHONY: all build install clean test package