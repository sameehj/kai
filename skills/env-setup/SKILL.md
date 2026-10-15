# Environment Setup

Use this skill to bootstrap developer machines and servers with a minimal, targeted stack.

## 1. Detect package manager first

Run:
- `exec: "command -v apt || command -v dnf || command -v pacman"`
- `exec: "cat /etc/os-release"`

Choose one package manager and stick to it for the session.

## 2. Ask intent before installing

Ask what workloads are needed:
- General backend/devops
- eBPF/kernel
- Embedded/Yocto
- Web/node

Install only what is needed.

## 3. Baseline packages

Install core tooling:
- `git`, `curl`, `wget`, `ca-certificates`
- build chain: `gcc`, `g++`, `make`, `cmake`, `pkg-config`
- `python3`, `python3-pip`, `python3-venv`

## 4. Workload add-ons

### Go/Rust/Node
- Go: distro package or official tarball to `/usr/local/go`
- Rust: `rustup` for user install
- Node: distro package or nvm when version pinning is needed

### eBPF
- `clang`, `llvm`, `libelf-dev`/`elfutils-libelf-devel`
- `bpftool`, `bpftrace`, kernel headers for running kernel

### Docker
- Install engine and CLI
- Add user to docker group
- Verify: `exec: "docker run --rm hello-world"`

## 5. Shell and SSH hygiene

- Ensure `~/.ssh` exists with `0700`
- Generate key only if user has no key:
  `exec: "test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"`
- Add PATH exports only when required; avoid duplicate lines.

## 6. Verify setup

Run quick checks:
- `exec: "git --version && gcc --version && python3 --version"`
- For optional stacks: `go version`, `rustc --version`, `docker --version`, `bpftrace --version`

## 7. Report format

- Summary of what was installed
- Any missing tools and exact install commands
- Reboot/log out requirements (docker group changes)
