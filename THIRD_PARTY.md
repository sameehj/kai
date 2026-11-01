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

## Apple frameworks (linked, not vendored)

CoreFoundation, Security, libcurl (the macOS SDK's), and in the app: SwiftUI, AppKit, NetworkExtension,
EndpointSecurity, LocalAuthentication. Versions are those of the toolchain in the release notes.
