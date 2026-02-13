.PHONY: build install clean test lint

BUILD_DIR = ./build
TEST_ARGS ?=

build:
	@mkdir -p $(BUILD_DIR)
	go build -o $(BUILD_DIR)/kai ./cmd/kai

install: build
	install -m 755 $(BUILD_DIR)/kai /usr/local/bin/kai

clean:
	rm -rf $(BUILD_DIR)

test:
	go test ./... $(TEST_ARGS)

lint:
	golangci-lint run ./...
