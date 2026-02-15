---
name: kernel-patch-check
description: Validate Linux kernel patches safely with build and regression-oriented checks.
---

# Kernel Patch Check

## When to use

Use when asked to:
- test a patch or patch series
- confirm patch builds on a target kernel tree
- identify likely regressions before CI

## Inputs expected

- kernel repo path
- patch file(s) or branch/commit range
- target config (defconfig/custom)
- architecture (default: x86_64)

## Workflow

### 1) Preflight
```bash
git -C <repo> status --porcelain
git -C <repo> rev-parse --abbrev-ref HEAD
git -C <repo> rev-parse HEAD
```

Abort if dirty tree unless user approves.

### 2) Apply patch safely
Single patch:
```bash
git -C <repo> apply --check <patch>
git -C <repo> apply <patch>
```

Series:
```bash
git -C <repo> am --signoff < <mbox>
```

### 3) Minimal compile validation
```bash
make -C <repo> mrproper
make -C <repo> defconfig
make -C <repo> -j"$(nproc)" bzImage modules
```

For custom config:
```bash
cp <config> <repo>/.config
make -C <repo> olddefconfig
make -C <repo> -j"$(nproc)" bzImage modules
```

### 4) Static and warning checks
```bash
make -C <repo> -j"$(nproc)" W=1
make -C <repo> C=1 CHECK=sparse
```

### 5) Report
Return:
1. apply status
2. build status
3. warnings summary
4. likely risky files/subsystems
5. rollback instructions

## Rollback
```bash
git -C <repo> reset --hard HEAD
git -C <repo> clean -fd
```
(Ask before destructive cleanup.)

## Output style

- **Result:** PASS / FAIL
- **Confidence:** high/medium/low
- **Evidence:** command + key output line
- **Next actions:** max 3, concrete
