# 🧠 KAI – Kernel-Aware Intelligence

> An AI-native eBPF runtime and MCP server for autonomous observability and kernel reasoning.

KAI turns the eBPF ecosystem into a composable, AI-operable package universe.
It bridges observability, security, and kernel introspection tools with the Model Context Protocol (MCP) — enabling LLMs and agents to reason about the kernel safely.

---

## Repository Structure

```
cmd/kaid          # Daemon exposing the MCP server
cmd/kaictl        # CLI for building, installing, and operating packages
pkg/runtime       # Runtime coordination, package lifecycle, and storage
pkg/mcp           # MCP server implementation
pkg/types         # Shared manifests and runtime types
configs/          # Runtime configuration and policy defaults
kai-recipes/      # (companion repo) published recipes and CI scripts
```

---

## Building

```bash
make build       # Build kaid and kaictl into ./bin
make test        # Run the Go test suite
```

---

## Quickstart

```bash
# 1. Build and start daemon
make build
./bin/kaid --mcp-stdio &

# 2. Interact via CLI
kaictl list-remote \
  --index https://raw.githubusercontent.com/sameehj/kai-recipes/main/recipes/recipes/index.yaml

# 3. Install and load a package
kaictl install falco-syscalls@0.37.0
kaictl attach falco-syscalls@0.37.0
```

> Requires the [`oras`](https://oras.land) CLI for OCI package downloads.

---

## Operating the Runtime

```bash
kaid --config configs/kai-config.yaml --debug
kaictl list-local
kaictl stream falco-syscalls@0.37.0
kaictl unload falco-syscalls@0.37.0
```

---

## MCP Integration

KAI exposes its operations over a Machine Context Protocol (MCP) server for AI or automation agents.

Available tools:

* `kai__list_remote`
* `kai__install_package`
* `kai__list_local`
* `kai__load_program`
* `kai__attach_program`
* `kai__unload_program`
* `kai__stream_events`
* `kai__inspect_state`

See [AGENTS.md](./AGENTS.md) for detailed integration examples.

---

## Testing and CI

Run locally:

```bash
make test
```

CI builds and tests automatically on each commit.
See `.github/workflows/runtime.yml`.

---

## Licensing

KAI is distributed under the MIT license (see `LICENSE`).
Upstream projects retain their original licenses, tracked in `THIRD_PARTY_LICENSES/`.
GPL-licensed packages are provided only as build recipes and must be compiled locally.