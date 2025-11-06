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
pkg/types         # Shared manifests and runtime types
configs/          # Runtime configuration and policy defaults
kai-recipes/      # (companion repo) published recipes and CI scripts
```

## Building

```bash
make build       # Build kaid and kaictl into ./bin
make test        # Run the Go test suite
```

All eBPF recipes are maintained in the companion repository
[`kai-recipes`](https://github.com/sameehj/kai-recipes), which publishes
object files as OCI artifacts.

## Installing Packages

1. Browse the remote catalog:
   ```bash
   kaictl list-remote \
    --index https://raw.githubusercontent.com/sameehj/kai-recipes/main/recipes/recipes/index.yaml
   ```
2. Install an OCI artifact into the local storage directory (default:
   `~/.local/share/kai/packages`):
   ```bash
   kaictl install falco-syscalls@0.37.0
   ```
   > Requires the [`oras`](https://oras.land) CLI to be available in `$PATH`.

## Runtime Usage

```bash
kaid --config configs/kai-config.yaml --debug     # start daemon

kaictl list-local                                 # list packages staged locally
kaictl list-remote                                # list packages from the remote index
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

- `kai__list_remote`
- `kai__install_package`
- `kai__list_local`
- `kai__load_program`
- `kai__attach_program`
- `kai__unload_program`
- `kai__stream_events`
- `kai__inspect_state`

These tools map directly to runtime operations exposed through `pkg/mcp`.

## Licensing

KAI itself is distributed under the MIT license (see `LICENSE`). Upstream
projects retain their respective licenses; a summary is maintained under
`THIRD_PARTY_LICENSES/`. GPL-licensed packages are distributed as recipes only
and must be built locally to satisfy license obligations.
