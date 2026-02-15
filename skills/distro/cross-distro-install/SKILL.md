---
name: cross-distro-install
description: Normalize dependency and setup steps across major Linux distributions.
---

# Cross-Distro Install

## When to use

Use when a workflow must run on multiple distros (Ubuntu, Debian, RHEL, Fedora, Amazon Linux, Arch).

## Detect distro
```bash
source /etc/os-release
echo "$ID $VERSION_ID"
uname -r
```

## Package manager matrix

- Ubuntu/Debian: `apt`
- RHEL/CentOS/Rocky/Alma: `dnf` or `yum`
- Fedora: `dnf`
- Amazon Linux: `dnf` or `yum`
- Arch: `pacman`

## Dependency templates

### Build essentials + kernel headers/tools

Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install -y build-essential git curl pkg-config clang llvm make bc bison flex libssl-dev libelf-dev dwarves linux-headers-"$(uname -r)"
```

RHEL/Fedora/Amazon Linux:
```bash
sudo dnf install -y gcc gcc-c++ make git curl pkgconf clang llvm bc bison flex openssl-devel elfutils-libelf-devel dwarves kernel-devel-"$(uname -r)" kernel-headers-"$(uname -r)"
```

Arch:
```bash
sudo pacman -Sy --noconfirm base-devel git curl pkgconf clang llvm bc bison flex openssl libelf pahole linux-headers
```

## eBPF toolchain checks
```bash
command -v bpftool || echo "bpftool missing"
command -v clang || echo "clang missing"
test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING
```

## Report format

- distro identified
- packages installed / missing
- incompatibilities found
- exact next command(s)

## Guardrails

- Never run package removal automatically.
- Ask before enabling third-party repos.
- Keep per-distro command blocks explicit.
