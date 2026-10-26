# v1 Step 5 — TLS validation where Kai is a client

## Where Kai is a TLS client
Exactly one place: the gateway's upstream connections to the model APIs
(`src/gateway.c` `forward()`), over libcurl. `src/net.c` is server/parsing only
(egress allowlist + ClientHello SNI). No update/telemetry/license client exists.

## What changed (src/gateway.c)
- `forward()` now sets, explicitly (defense in depth over libcurl defaults):
  - `CURLOPT_SSL_VERIFYPEER = 1`, `CURLOPT_SSL_VERIFYHOST = 2`
  - `CURLOPT_SSLVERSION = CURL_SSLVERSION_TLSv1_2` (TLS 1.2 minimum)
  - `CURLOPT_FOLLOWLOCATION = 0`
  - product builds only: `CURLOPT_PROTOCOLS(_STR) = https` and the same for
    redirects — any non-HTTPS scheme is refused outright.
- `upstream_base()`: the `KAI_GATEWAY_*` env override is now compiled in **only**
  under `KAI_TEST_DIRECT_POLICY`. A shipped gateway's upstreams are exactly the
  fixed https list (`UPSTREAMS[]`: api.anthropic.com, api.openai.com,
  openrouter.ai). Neither the policy nor the environment can redirect them.
- A TLS/connection failure now also writes an audit record
  (`kai_audit("gateway", …, "block", "upstream", …)`) so it surfaces in
  Activity. It already failed closed (502) and still does.
- No custom trust override, no CA override, no "insecure" path anywhere
  (confirmed by code search).

## Tests
- **Negative (tests/gateway/run_tls_tests.sh)** — local HTTPS servers with a
  self-signed, an expired, and a wrong-hostname certificate; the gateway is
  pointed at each and must return **502**. All three PASS. Wired into
  `make test`. (A new script because the existing `run_gateway_tests.sh` holds
  synthetic secret fixtures that the storage wall won't let an agent read.)
- **Positive (valid upstream works):** covered by the existing
  `run_gateway_tests.sh` end-to-end suite (request → clean → forward → stream
  back) and by live use. A locally-trusted https cert isn't created here because
  that would require modifying the system keychain; noted rather than faked.
- **Code search clean:** no `VERIFYPEER,0` / `VERIFYHOST,0` / `SSL_VERIFY_NONE` /
  `insecure` / `CAINFO` / pinning anywhere in `src/`.

## Live-test status
- Negative TLS validation: **live PASS** (local bad-cert servers, this run).
- Fixed-upstream / no-redirect in product: **unit/structural** (env override
  compiled out; verified by build). A full product-build live check is covered
  under Step 7 distribution.
