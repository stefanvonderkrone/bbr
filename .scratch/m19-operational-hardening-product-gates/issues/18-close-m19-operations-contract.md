# 18 — Close the M19 operations contract

**What to build:** Maintainers receive one current operations and product contract for M19, backed by final native acceptance and a recorded Candidate Session fan-out decision.

**Blocked by:** 11 — Establish four-target native CI; 12 — Add reproducible source identity; 13 — Validate release identity; 14 — Harden Credential and transport operations; 15 — Gate bounded Candidate Session acquisition; 16 — Add the Reviewer Verdict Bitbucket contract; 17 — Add Reviewer Verdict Actions.

**Status:** done

- [x] Product and operations documentation describes only behavior that has landed.
- [x] Documentation covers required CI, build identity, release validation, Credential handling, proxy behavior, live-check opt-ins, the selected Candidate Session policy, and Reviewer Verdict Actions.
- [x] The external-dependency ADR and context language agree with the final `StdHttpClient`, `HttpClient`, Credential, Candidate Session, and Reviewer Verdict behavior.
- [x] The recorded fan-out evidence states either a passing go result or a failed no-go result with sequential production behavior.
- [x] The format check and `zig build test --summary all` pass.
- [x] All four required native CI jobs pass with their stable names.
- [x] Release validation publishes no artifact, and required CI uses no Bitbucket Credential.
- [x] M19 adds no Credential store, login flow, release publication, libcurl adapter, bbr-specific proxy setting, configurable acquisition concurrency, branch cancellation, merge Action, or decline Action.
