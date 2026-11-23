<!-- SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial -->
# Third-party code

Everything Kai builds from that it didn't write. Release builds compile these exact files. Third-party code isn't
covered by Kai's CLA; its own license applies.

SHA-256 in `src/sha256.c` is an original, from-scratch implementation of the FIPS 180-4 algorithm, written for this
project and covered by Kai's own license.

When adding third-party code, it must be under a permissive license (MIT, BSD, Apache-2.0), recorded here with its
upstream commit and hashes, and kept in `third_party/` with its original license file.

## cJSON

| | |
|---|---|
| What | JSON parser and printer, `third_party/cjson/` (MIT, `third_party/cjson/LICENSE`) |
| Upstream | https://github.com/DaveGamble/cJSON |
| Version | v1.7.19 (`CJSON_VERSION` 1.7.19) |
| Upstream commit | `c859b25da02955fef659d658b8f324b5cde87be3` (tag `v1.7.19`) |
| `cJSON.h` SHA-256 | `25b0145150d500498e4d209cec69c18c42cf818bffcc54690be3b895a2a16dee`, identical to upstream |
| `cJSON.c` SHA-256 | `607e756460fa0de37d20a7a9181f2de29c97bfb7ce5a0e6c2f548243836cd852` (Kai's copy) |
| Upstream `cJSON.c` SHA-256 | `298581a04a36c0165da4b0aade235c23088cb2faa58651d720ea2f3706ed0b0d` |
| Local changes | Three hardening patches, the exact diff in [`third_party/cjson/kai-patches.diff`](third_party/cjson/kai-patches.diff): a NULL check in `cJSON_SetNumberHelper`, and the nesting limit (`CJSON_NESTING_LIMIT`) enforced when printing arrays and objects, not only when parsing. |

Checked on 2026-10-31 by cloning the upstream tag and comparing hashes. To recheck:

```sh
git clone --depth 1 --branch v1.7.19 https://github.com/DaveGamble/cJSON.git /tmp/cjson
shasum -a 256 /tmp/cjson/cJSON.[ch] third_party/cjson/cJSON.[ch]
diff -u /tmp/cjson/cJSON.c third_party/cjson/cJSON.c    # = kai-patches.diff
```

## musl regex (Windows build only)

| | |
|---|---|
| What | POSIX regular expressions (TRE-based `regcomp`/`regexec`), `third_party/musl-regex/` (MIT, `third_party/musl-regex/COPYRIGHT`). MSVC has no `<regex.h>`; macOS and Linux use their system's. Compiled only by the CMake build on Windows. |
| Upstream | https://git.musl-libc.org/cgit/musl, tag `v1.2.5`, files `src/regex/regcomp.c`, `regexec.c`, `tre-mem.c`, `tre.h` |
| `regcomp.c` SHA-256 | `56b0a765e084a5cd3ed7113a893b50d259265ba76b6bea98889c45d7aec302a0`, identical to upstream |
| `regexec.c` SHA-256 | `bd8acb924bd3168a30a46a1f7ec2c4956df98c46488a898d73eb23546642c0d5` (Kai's copy) |
| Upstream `regexec.c` SHA-256 | `072e8a1092c98830b48e784fb74ce486f7c39e27207f79f1dd161e2c5d86ba77` |
| `tre-mem.c` SHA-256 | `4721979ce365a395fd7644335c847a8a97913e87f14348641f7f199b57b93e28`, identical to upstream |
| `tre.h` SHA-256 | `e734e68decc33b5ee983db12cabcbdd2589c2d16088677228087b0e5dc365cf3`, identical to upstream |
| Local changes | One line for MSVC (`regmatch_t pmatch[restrict]` -> `regmatch_t *restrict pmatch`), the exact diff in [`third_party/musl-regex/kai-patches.diff`](third_party/musl-regex/kai-patches.diff). musl's own headers are replaced by `compat/win/regex.h` (same struct layout) and `compat/win/musl_regex_prelude.h`; `regerror` messages are in `src/platform_win.c`. |

Downloaded on 2026-11-22 from the URLs above.

## Apple frameworks (linked, not vendored)

CoreFoundation, Security, libcurl (the macOS SDK's), and in the app: SwiftUI, AppKit, NetworkExtension,
EndpointSecurity, LocalAuthentication. Versions are those of the toolchain in the release notes.

## llama.cpp (Kai.app, optional local phraser)

- Source: https://github.com/ggml-org/llama.cpp, release `b12182` (prebuilt `llama.xcframework`, pinned by URL and checksum in `app/macos/Packages/LlamaBinary/Package.swift`).
- License: MIT.
- Models are not bundled; the default (Qwen3.5-0.8B GGUF, Apache-2.0) is downloaded only after the user agrees.

## Agent logos

The official Claude, Cursor and OpenAI marks bundled with the app, their sources and the trademark notice: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
