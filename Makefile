.PHONY: build install clean test lint

BINARIES = kai kai-mcp kai-gateway
BUILD_DIR = ./build

build:
	@mkdir -p $(BUILD_DIR)
	go build -o $(BUILD_DIR)/kai ./cmd/kai
	go build -o $(BUILD_DIR)/kai-mcp ./cmd/kai-mcp
	go build -o $(BUILD_DIR)/kai-gateway ./cmd/kai-gateway

install: build
	install -m 755 $(BUILD_DIR)/kai /usr/local/bin/kai
	install -m 755 $(BUILD_DIR)/kai-mcp /usr/local/bin/kai-mcp
	install -m 755 $(BUILD_DIR)/kai-gateway /usr/local/bin/kai-gateway
	mkdir -p /usr/local/share/kai/tools
	cp -r tools/* /usr/local/share/kai/tools/

clean:
	rm -rf $(BUILD_DIR)

test:
	go test ./...

lint:
	golangci-lint run ./...
