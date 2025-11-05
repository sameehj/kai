# Repository Guidelines

## Project Structure & Module Organization
The repository centers on buildable recipes. Define each recipe in `recipes/recipes/<name>.yaml`; the `name` field and filename should match. The build pipeline clones upstream sources into `recipes/build/<name>/src` and keeps generated binaries in `recipes/dist/<name>/`. Keep shared automation in `recipes/scripts/`, and reserve `runtime/` for runtime assets or configuration shipped with the agent.

## Build, Test, and Development Commands
Run `./recipes/scripts/build_recipe.sh recipes/recipes/tetragon-process-monitor.yaml` to materialize the example recipe; swap in other manifests as you add them. During iteration, reuse the cached clone under `recipes/build/<name>/src` and rerun `make -C recipes/build/<name>/src bpf` (or whatever commands are declared in the manifest) before re-invoking the script. Inspect outputs in `recipes/dist/<name>/` and add new programs there via the `outputs.programs[].path` section of the manifest.

## Coding Style & Naming Conventions
YAML manifests use two-space indentation, lower-hyphen keys, and explicit versions; keep fields ordered logically (metadata, upstream, build, outputs). Script contributions stay POSIX-friendly Bash, include `set -euo pipefail`, and prefer descriptive, kebab-cased filenames (e.g., `sync_recipes.sh`). When touching upstream sources inside `src/`, respect their native tooling (`gofmt`, `golangci-lint`, etc.) before committing deltas.

## Testing Guidelines
Smoke-test every recipe after build: inside `recipes/build/<name>/src`, run `go test ./...` for Go projects or the upstream’s documented test entrypoint. Add recipe-specific validation commands to `.build.commands[]` so CI can reproduce them. Verify that artifact hashes remain stable between runs and document any intentional deviations in the manifest comments.

## Commit & Pull Request Guidelines
There is no existing history, so adopt Conventional Commits (e.g., `feat: add tetragon recipe`) to establish consistency. Each PR should list the affected recipes, link to any upstream issues, and attach build logs or sample output from `recipes/dist/`. Include rollback notes when modifying existing recipes so reviewers can validate the impact quickly.

## Environment & Tooling
Ensure `bash`, `git`, `yq`, and any recipe-specific toolchains (such as `go`, `clang`, or container runtimes) are available in `$PATH`. Favor reproducible versions by pinning `upstream.ref` to tags or commit SHAs. Document any additional environment expectations in the corresponding recipe YAML under a `notes` or `requirements` key so other agents can mirror your setup.
