# 14 — Harden Credential and transport operations

**What to build:** `StdHttpClient` remains the only production transport and honors standard proxy configuration without an unsafe direct fallback. Maintainers can run Credential-gated checks without placing Credential data in repository files, shell history, logs, or diagnostics.

**Blocked by:** 13 — Validate release identity.

**Status:** done

- [x] Production loads supported uppercase and lowercase standard proxy environment variables through `initDefaultProxies` and adds no bbr-specific proxy setting.
- [x] Invalid or unsupported configured proxy data stops the operation with a sanitized configuration or transport failure. No request retries through a direct connection.
- [x] Transport failures remain distinct from Bitbucket `ApiError` values and can report a transport error name plus a Credential-free request location.
- [x] Logs and diagnostics omit Authorization values, proxy authentication, token-bearing URLs, and Credential values.
- [x] Hermetic tests cover uppercase and lowercase proxy variables, invalid proxy data, no direct fallback, transport-error separation, and existing `ApiError` classification.
- [x] `StdHttpClient` remains the only production `HttpClient` adapter. M19 adds no libcurl dependency.
- [x] The external-dependency ADR records the measured no-libcurl decision and keeps `HttpClient` as the replacement boundary.
- [x] Operations guidance documents the three existing Credential environment variables and a macOS Keychain launch pattern with placeholders.
- [x] Required CI remains Credential-free. Direct connectivity, blob, Comment mutation, Reviewer Verdict mutation, and other live checks remain explicit local opt-ins.
