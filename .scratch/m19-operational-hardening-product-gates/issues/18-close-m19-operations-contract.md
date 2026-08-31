# 18 — Close the M19 operations contract

**What to build:** Maintainers receive one current operations and product contract for M19, backed by final native acceptance and a recorded Candidate Session fan-out decision.

**Blocked by:** 11 — Establish four-target native CI; 12 — Add reproducible source identity; 13 — Validate release identity; 14 — Harden Credential and transport operations; 15 — Gate bounded Candidate Session acquisition; 16 — Add the Reviewer Verdict Bitbucket contract; 17 — Add Reviewer Verdict Actions.

**Status:** ready-for-agent

- [ ] Product and operations documentation describes only behavior that has landed.
- [ ] Documentation covers required CI, build identity, release validation, Credential handling, proxy behavior, live-check opt-ins, the selected Candidate Session policy, and Reviewer Verdict Actions.
- [ ] The external-dependency ADR and context language agree with the final `StdHttpClient`, `HttpClient`, Credential, Candidate Session, and Reviewer Verdict behavior.
- [ ] The recorded fan-out evidence states either a passing go result or a failed no-go result with sequential production behavior.
- [ ] The format check and `zig build test --summary all` pass.
- [ ] All four required native CI jobs pass with their stable names.
- [ ] Release validation publishes no artifact, and required CI uses no Bitbucket Credential.
- [ ] M19 adds no Credential store, login flow, release publication, libcurl adapter, bbr-specific proxy setting, configurable acquisition concurrency, branch cancellation, merge Action, or decline Action.
