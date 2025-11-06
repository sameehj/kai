SHELL := /usr/bin/env bash
GO ?= go

.PHONY: all build test install recipe recipes docker-build clean

all: build

build:
	$(GO) mod tidy
	$(GO) build -o bin/kaid ./cmd/kaid
	$(GO) build -o bin/kaictl ./cmd/kaictl

test:
	GOCACHE=$(PWD)/.gocache $(GO) test ./... -count=1 -v

install: build
	sudo install -Dm755 bin/kaid /usr/local/bin/kaid
	sudo install -Dm755 bin/kaictl /usr/local/bin/kaictl

recipe:
	./recipes/scripts/build_recipe.sh $(RECIPE)

recipes:
	@for r in $$(yq -r '.packages[].recipe' recipes/recipes/index.yaml); do \
		./recipes/scripts/build_recipe.sh $$r || exit 1; \
	done

docker-build:
	docker build -t kai:dev .

clean:
	rm -rf bin/ recipes/build/ recipes/dist/
