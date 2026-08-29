# 26 — Prove Native Grammar Support

**What to build:** Prove that the complete native Grammar feature executes on every supported target rather than relying on cross-compilation alone.

**Blocked by:** 25 — Publish the Complete UserGrammar Lifecycle.

**Status:** done

- [x] The hermetic suite executes natively on macOS x86_64, macOS aarch64, Linux x86_64, and Linux aarch64.
- [x] Each target runs an RE2 wrapper smoke test, a dynamic UserGrammar fixture load, and the real CLI lifecycle fixture.
- [x] Failures identify the target and failing native component without requiring a Credential or network access.
- [x] The supported-target claim is withheld for any target that has only cross-compiled evidence.
- [x] The default test command remains green, and credential-gated Bitbucket checks remain explicit.
