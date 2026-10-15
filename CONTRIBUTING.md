# Contributing to Kai

Thanks for helping build Kai. This guide gets you from clone to merged.

## Build and test

```sh
make            # builds ./kai and libkai.a
make test       # unit tests + hook integration tests
make asan       # same tests under AddressSanitizer + UBSan (run before a PR)
```

Kai is C11. The only dependencies are POSIX regex and a vendored MIT copy of
cJSON. It builds with `clang` or `gcc` on macOS and Linux with no extra flags.

## Sign the CLA

Your first pull request gets an automatic comment from the CLA bot. One click
records your agreement (see [`CLA.md`](CLA.md)). We can't merge until it's
signed — this is what lets Kai stay GPLv3 *and* fund itself through commercial
licenses.

## Good first contributions

These are self-contained and easy to review — a great place to start:

- **New secret detectors.** Add a pattern to `BUILTIN_SECRETS` in
  `src/policy.c`, and a test case in `tests/run_tests.c`. Patterns must be
  POSIX ERE and must avoid `\b` and `\s` (not portable to macOS's BSD regex) —
  see the note in that file.
- **New agent integrations.** Add a handler in `src/hooks.c` and wiring in
  `src/install.c` for another agent (Windsurf, Cline, Aider, Codex…). Add
  fixtures to `tests/hooks/run_hook_tests.sh`.
- **Attack-suite cases.** Add adversarial inputs that *should* be caught (or
  that currently slip through — mark them `KNOWN_GAP`).
- **Policy rules.** Propose sharper upload/injection patterns.

## Rules for the privileged core

Kai is a security tool, so the core (`libkai`) holds to a few rules:

1. **No secret values in the audit log, ever.** Log rule names and counts, not
   the matched text.
2. **Fail closed on the policy.** A broken policy denies agent actions; it never
   silently allows them.
3. **No new runtime dependencies** without discussion. The point is a small,
   auditable core.
4. **Every public API function tolerates NULL** inputs without crashing.
5. **`make asan` must pass** with no leaks or UB.

## Pull request checklist

- [ ] `make test` and `make asan` pass.
- [ ] New behavior has a test.
- [ ] No secrets in logs; policy still fails closed.
- [ ] Third-party code (if any) is permissively licensed and listed in
      `THIRD_PARTY.md`.
- [ ] CLA signed.

## Reporting security issues

Do **not** open a public issue for a vulnerability. See [`SECURITY.md`](SECURITY.md).
