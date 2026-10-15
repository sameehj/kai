# Build Debug

Use this skill when builds fail. Do not guess; identify the build system and first failing error.

## 1. Capture the real failure

- `read` the build log or run one failing build command with `exec`.
- Extract the first error, not the final cascade message.

## 2. Identify build system

Use markers:
- `Makefile` -> make
- `CMakeLists.txt` -> cmake
- `Cargo.toml` -> cargo
- `bitbake` output / `.bb` files -> bitbake
- `go.mod` -> go
- `package.json` -> npm/yarn

## 3. System-specific triage

### make/cmake
- Missing headers/libs: check include and linker paths.
- Undefined references: missing link flags or wrong link order.
- `find_package` failures: verify dev package installed and `CMAKE_PREFIX_PATH`.

### bitbake
- Fetch errors: mirrors, network, SRC_URI.
- Layer mismatch: `bblayers.conf`, branch compatibility.
- Dependency issues: `DEPENDS`, `RDEPENDS`, provider conflicts.

### cargo
- Feature/version conflicts: inspect lockfile and features.
- Native deps missing: openssl/zlib/sqlite dev packages.

### go
- Module resolution: `go env`, proxy settings, `go mod tidy`.
- CGO failures: missing C toolchain or headers.

### npm
- Node version mismatch: check engines and lockfile.
- Peer dependency conflicts and global install permission issues.

## 4. Cross compile and kernel specifics

- Validate toolchain prefix and sysroot path.
- For kernel modules: verify `uname -r` headers match target kernel.

## 5. Output format

- Root cause
- Exact evidence lines
- Minimal fix first
- Optional hardening follow-ups
