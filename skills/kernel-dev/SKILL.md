# Kernel Development

Use this skill for out-of-tree modules, kernel builds, and regression tracking.

## 1. Module build workflow

- Verify running kernel: `exec: "uname -r"`
- Verify headers path exists
- Build with:
  `exec: "make -C /lib/modules/$(uname -r)/build M=$(pwd) modules"`

## 2. Load/test cycle

- `exec: "sudo insmod <module>.ko"`
- `exec: "dmesg --time-format iso | tail -120"`
- unload with `sudo rmmod <module>`

## 3. Kernel build flow

- clone source
- baseline config via `make olddefconfig`
- build with `make -j$(nproc)`
- keep install and bootloader changes explicit and confirmed

## 4. Regression isolation

Use `git bisect` with reproducible pass/fail test command.

## 5. Patch/CVE tracking

- compare running version to upstream stable
- identify whether fix commit is present in tree
- report affected targets clearly

## 6. Safe testing

Prefer VM/QEMU test boot before production rollout.

## 7. Output

- What changed
- Evidence (build/log lines)
- Risk and rollback
