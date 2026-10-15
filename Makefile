SHELL := /bin/bash

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X main.version=$(VERSION)
GOCACHE ?= $(CURDIR)/.cache/go-build

.PHONY: build test test-integration lint clean release demo-up demo-inject demo-down fmt tidy

build:
	@mkdir -p bin $(dir $(GOCACHE))
	GOCACHE=$(GOCACHE) go build -ldflags "$(LDFLAGS)" -o bin/kai ./cmd/kai

test:
	@mkdir -p $(dir $(GOCACHE))
	GOCACHE=$(GOCACHE) go test ./internal/... -v

test-integration:
	@mkdir -p $(dir $(GOCACHE))
	GOCACHE=$(GOCACHE) go test ./tests/integration/... -tags=integration -v

lint:
	golangci-lint run ./...

fmt:
	gofmt -w $$(rg --files -g '*.go')

tidy:
	@mkdir -p $(dir $(GOCACHE))
	GOCACHE=$(GOCACHE) go mod tidy

clean:
	rm -rf bin/ .cache/

demo-up:
	cd demo/slow-app && docker compose -f docker-compose.yaml up -d

demo-inject: demo-up
	cd demo/slow-app && bash inject-problems.sh

demo-down:
	cd demo/slow-app && docker compose -f docker-compose.yaml down

release:
	goreleaser release --clean
