#!/usr/bin/env bash
set -euo pipefail

echo "🔧 Building eBPF programs..."

if ! command -v clang >/dev/null 2>&1; then
    echo "❌ clang not found. Install with: sudo apt install clang llvm"
    exit 1
fi

if ! command -v bpftool >/dev/null 2>&1; then
    echo "❌ bpftool not found. Install with: sudo apt install linux-tools-$(uname -r)"
    exit 1
fi

if [ ! -f "/sys/kernel/btf/vmlinux" ]; then
    echo "❌ /sys/kernel/btf/vmlinux not found. Install a BTF-enabled kernel."
    exit 1
fi

if [ ! -f "vmlinux.h" ]; then
    echo "  📘 Generating vmlinux.h..."
    sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
    echo "  ✅ vmlinux.h generated."
fi

arch_include="/usr/include/$(uname -m)-linux-gnu"
[ -d "$arch_include" ] || arch_include="/usr/include"

CLANG_FLAGS="-O2 -g -target bpf \
    -D__TARGET_ARCH_x86 \
    -I. \
    -I$arch_include \
    $(pkg-config --cflags libbpf 2>/dev/null || true)
"

for dir in recipes/sensors/ebpf/*; do
    name=$(basename "$dir")
    src="$dir/$name.bpf.c"
    out="$dir/$name.o"

    if [ -f "$src" ]; then
        echo "  Building $name..."
        clang $CLANG_FLAGS -c "$src" -o "$out"
        echo "  ✅ $out"
    fi
done

echo "✅ All eBPF programs built"
