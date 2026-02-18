SHELL := /bin/bash

GO ?= go
BINARY ?= kai
PKG ?= ./...
BUILD_DIR ?= bin

.PHONY: all build test race fmt lint tidy clean install run daemon-start daemon-stop e2e ci

all: fmt test build

ci: fmt lint test build

build:
	@mkdir -p $(BUILD_DIR)
	$(GO) build -o $(BUILD_DIR)/$(BINARY) ./cmd/kai

test:
	$(GO) test $(PKG)

race:
	$(GO) test -race $(PKG)

fmt:
	$(GO) fmt ./...

lint:
	$(GO) vet ./...

tidy:
	$(GO) mod tidy

install:
	$(GO) install ./cmd/kai

run:
	$(GO) run ./cmd/kai

daemon-start:
	$(GO) run ./cmd/kai daemon start

daemon-stop:
	$(GO) run ./cmd/kai daemon stop

e2e: build
	./scripts/test-e2e.sh

clean:
	rm -rf $(BUILD_DIR)
