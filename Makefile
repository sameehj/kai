.PHONY: build test clean install lint run-daemon run-flow validate-recipes

# Build binaries
build:
	@echo "Building kaid..."
	go build -o bin/kaid ./cmd/kaid
	@echo "Building kaictl..."
	go build -o bin/kaictl ./cmd/kaictl

# Install binaries to $$GOPATH/bin
install:
	go install ./cmd/kaid
	go install ./cmd/kaictl

# Run tests
test:
	go test -v ./...

# Run linter
lint:
	golangci-lint run

# Clean build artifacts
clean:
	rm -rf bin/
	rm -f *.log

# Run kaid daemon
run-daemon:
	go run ./cmd/kaid

# Example: run a flow
run-flow:
	go run ./cmd/kaictl run-flow flow.cpu_spike_investigator

# Validate all recipes
validate-recipes:
	@echo "Validating recipes..."
	@for f in recipes/flows/**/flow.yaml; do \
		echo "Checking $$f"; \
		go run ./cmd/kaictl validate-flow $$f || exit 1; \
	done
