# Third-party code

Kai vendors the following third-party code. It is not covered by Kai's CLA; its
own license applies.

| Component | Location | License | Notes |
|---|---|---|---|
| cJSON | `third_party/cjson/` | MIT | JSON parsing for hook I/O and settings merge. Unmodified. |

SHA-256 in `src/sha256.c` is an original, from-scratch implementation of the
FIPS 180-4 algorithm, written for this project and covered by Kai's own license.

When adding third-party code, it must be under a permissive license (MIT, BSD,
Apache-2.0), recorded here, and kept in `third_party/` with its original license
file.
