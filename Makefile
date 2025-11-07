SHELL := /usr/bin/env bash
GO ?= go
GOENV := GOCACHE=$(PWD)/.gocache
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GIT_COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS := -X github.com/sameehj/kai/pkg/version.Version=$(VERSION)
LDFLAGS += -X github.com/sameehj/kai/pkg/version.GitCommit=$(GIT_COMMIT)
LDFLAGS += -X github.com/sameehj/kai/pkg/version.BuildDate=$(BUILD_DATE)

.PHONY: all build test install docker-build clean

all: build

build:
	$(GOENV) $(GO) mod tidy
	$(GOENV) $(GO) build -ldflags "$(LDFLAGS)" -o bin/kaid ./cmd/kaid
	$(GOENV) $(GO) build -ldflags "$(LDFLAGS)" -o bin/kaictl ./cmd/kaictl

test:
	$(GOENV) $(GO) test ./... -count=1 -v

install: build
	sudo install -Dm755 bin/kaid /usr/local/bin/kaid
	sudo install -Dm755 bin/kaictl /usr/local/bin/kaictl

docker-build:
	docker build -t kai:dev .

clean:
	rm -rf bin/
