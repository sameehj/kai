KAI – Kernel-Aware Intelligence
================================

KAI is an AI-native eBPF package manager and runtime. It can build popular eBPF
programs from upstream sources, install them into a managed runtime directory,
and expose the resulting capabilities through an MCP (Model Context Protocol)
server for agent orchestration.

## Project Layout

```
cmd/kaid          # Daemon exposing the MCP server
cmd/kaictl        # CLI for building, installing, and operating packages
pkg/runtime       # Runtime coordination, package lifecycle, and storage
pkg/mcp           # MCP server implementation
pkg/registry      # Recipe index helpers
pkg/types         # Shared manifests and runtime types
recipes/          # Build recipes, artifacts, and builder tooling
configs/          # Runtime configuration and policy defaults
```

## Building

```bash
make build       # Build kaid and kaictl into ./bin
make test        # Run the Go test suite
make recipes     # Build every recipe in recipes/recipes/index.yaml
```

Artifacts are written to `recipes/dist/<recipe-name>/`.

## Installing Packages

1. Build recipes with `make recipes` or an individual recipe with:
   ```bash
   make recipe RECIPE=recipes/recipes/falco-syscalls.yaml
   ```
2. Install the resulting artifact into the runtime storage directory (artifacts land in `recipes/dist/<name>/<version>`):
   ```bash
   kaictl install falco-syscalls@0.37.0
   ```
   By default the CLI looks for artifacts in `recipes/dist/`.

## Runtime Usage

```bash
kaid --config configs/kai-config.yaml --debug     # start daemon

kaictl list                                       # list installed & loaded packages
kaictl load falco-syscalls@0.37.0                 # load package metadata
kaictl attach falco-syscalls@0.37.0               # attach the entry program
kaictl stream falco-syscalls@0.37.0               # stream events from default buffer
kaictl unload falco-syscalls@0.37.0               # detach and unload
kaictl remove falco-syscalls@0.37.0               # remove from runtime storage
```

The CLI communicates with `kaid` over the MCP bridge. When running under an
agent framework it is common to start the daemon in stdio mode:

```bash
./bin/kaid --config configs/kai-config.yaml --mcp-stdio
```

## MCP Integration

`mcp.json` advertises the daemon as an MCP stdio server. The published tool
names are:

- `kai__list_packages`
- `kai__install_package`
- `kai__remove_package`
- `kai__load_program`
- `kai__attach_program`
- `kai__unload_program`
- `kai__stream_events`
- `kai__inspect_state`

These tools map directly to runtime operations exposed through `pkg/mcp`.

## Included Recipes

| Package                 | Version  | Upstream                                   |
| ----------------------- | -------- | ------------------------------------------ |
| falco-syscalls          | 0.37.0   | https://github.com/falcosecurity/falco     |
| tracee-syscalls         | 0.15.1   | https://github.com/aquasecurity/tracee     |
| bcc-runqlat             | 0.30.0   | https://github.com/iovisor/bcc             |
| bcc-biolatency          | 0.30.0   | https://github.com/iovisor/bcc             |
| hubble-netflow          | 1.15.0   | https://github.com/cilium/hubble           |
| bpftool-inspector       | 7.4.0    | https://github.com/libbpf/bpftool          |
| game-of-life            | 1.0.0    | https://github.com/isovalent/game-of-life |
| tetragon-process-monitor| 1.0.0    | https://github.com/cilium/tetragon         |

## Licensing

KAI itself is distributed under the MIT license (see `LICENSE`). Upstream
projects retain their respective licenses; a summary is maintained under
`THIRD_PARTY_LICENSES/`.
