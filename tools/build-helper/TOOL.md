---
name: build-helper
description: Detect build systems, check dependencies, run builds, parse errors
metadata:
  kai:
    emoji: 🏗
    requires:
      bins: []
    os: [linux, darwin, windows]
---

# Build Helper

## When to use
- "Build this project"
- "Why is my build failing?"
- Checking if build dependencies are installed
- Understanding what build system a project uses

## When NOT to use
- For running/deploying applications (that's beyond build)
- For package management advice outside build context

## How to use

### Detect build system
Look for these files in the project root (check in order):
- `Makefile` or `GNUmakefile` → Make
- `CMakeLists.txt` → CMake
- `Cargo.toml` → Rust/Cargo
- `package.json` → Node.js/npm
- `go.mod` → Go
- `build.gradle` or `build.gradle.kts` → Gradle
- `pom.xml` → Maven
- `meson.build` → Meson
- `setup.py` or `pyproject.toml` → Python
- `*.pro` → qmake
- `bitbake` layer conf → Yocto/BitBake

### Build commands by system
- Make: `make -j$(nproc)`
- CMake: `mkdir -p build && cd build && cmake .. && make -j$(nproc)`
- Cargo: `cargo build --release`
- npm: `npm install && npm run build`
- Go: `go build ./...`
- Gradle: `./gradlew build`
- Maven: `mvn package`
- Meson: `meson setup builddir && meson compile -C builddir`
- Python: `pip install -e .` or `python -m build`

### Check dependencies
- Ubuntu/Debian: `dpkg -l | grep <package>` or `apt list --installed 2>/dev/null | grep <package>`
- Fedora/RHEL: `rpm -qa | grep <package>`
- macOS: `brew list | grep <package>`
- General: `which <binary>` to check if a command exists

### Parse build errors
- Run the build, capture stderr
- Look for first occurrence of `error:`, `FAILED`, `fatal`, `undefined reference`, `No such file`
- For C/C++: missing headers → suggest package to install
- For Rust: read the compiler error message (it's usually excellent)
- For Node: check `npm ls` for dependency conflicts
- For Go: `go mod tidy` often fixes dependency issues

### Cross-compilation
- Check toolchain: `which <cross-prefix>-gcc`
- Check sysroot: `ls <sysroot>/usr/include/`
- Common fix: install the cross-compilation package for the target arch

## Platform notes
- On macOS, use `sysctl -n hw.ncpu` instead of `nproc` for parallel jobs
- On Windows/WSL, prefer building inside WSL for Linux targets
- For embedded targets, check if the toolchain is in PATH

## Output guidance
When a build fails, find the FIRST error (not the cascade of subsequent errors). Identify whether it's a missing dependency, a code error, or a configuration issue. Suggest the specific fix.
