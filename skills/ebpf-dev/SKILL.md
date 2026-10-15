# eBPF Development

Use this skill for bpftrace/libbpf/bpftool workflows.

## 1. Environment checks

- `exec: "uname -r && bpftool version || true && bpftrace --version || true"`
- `exec: "clang --version"`
- Confirm kernel headers/BTF availability.

## 2. Fast prototyping with bpftrace

Start with one-liners for hypotheses, then convert to maintained programs.

## 3. libbpf workflow

- Write `<name>.bpf.c`
- Compile with `clang -target bpf ...`
- Generate skeleton and userspace loader where needed
- Attach to tracepoint/kprobe/uprobe/XDP depending on use case

## 4. Verifier error triage

Common classes and fixes:
- invalid mem access: initialize pointers/stack and bound-check accesses
- back-edge/unbounded loop: use bounded loops or unroll
- invalid map access: key/value struct mismatch
- unreachable instruction: clean control flow and early returns

## 5. Inspect runtime state

- `exec: "bpftool prog show"`
- `exec: "bpftool map show"`
- `exec: "bpftool map dump id <id>"`

## 6. Performance guidance

- Prefer per-CPU maps for high write contention
- Use ring buffer for structured event streaming
- Keep programs small and split by attach point

## 7. Deliverables

Always provide:
- source files touched
- compile/load commands
- expected output and rollback/unload steps
