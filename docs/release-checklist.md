# Release Checklist

1. Run tests
   - `GOCACHE=/tmp/go-build-cache go test ./...`
2. Update dependencies
   - `GOCACHE=/tmp/go-build-cache go mod tidy`
3. Build binaries
   - `make build`
4. Verify MCP stdio
   - `./bin/kai-mcp`
5. Verify gateway startup
   - `./bin/kai-gateway --addr 127.0.0.1:9910`
6. Verify tool watcher
   - Create a new tool under `~/.kai/tools/` and ensure reload
7. Review config defaults
   - `config.example.yaml`
8. Update docs
   - `README.md`, `docs/mcp.md`
9. Tag release
   - `git tag -a vX.Y.Z -m "release vX.Y.Z"`
