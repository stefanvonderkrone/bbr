# 15 — Gate bounded Candidate Session acquisition

**What to build:** Remote Candidate Session acquisition uses at most two active requests only when a live gate proves the required latency gain. Either outcome leaves one tested production policy and no dormant alternative.

**Blocked by:** 14 — Harden Credential and transport operations.

**Status:** ready-for-agent

- [ ] The acquisition policy treats PullRequest, RawDiff, and Comments as required. Authenticated Account failure still produces a read-only Candidate Session.
- [ ] A bounded implementation never has more than two active requests and uses one `StdHttpClient` connection pool for one Candidate Session attempt.
- [ ] Comments wait for PullRequest commit data and take priority over RawDiff when both become ready. Candidate Session assembly remains in PullRequest, RawDiff, and Comments order.
- [ ] The first required failure stops later top-level work. All started work completes before shared state is destroyed, and logical order selects the reported required failure.
- [ ] Each acquisition branch owns its allocations. Failed, superseded, stale, and rejected candidates release all owned data.
- [ ] Only the current replacement intent can publish a complete Candidate Session. Failed replacement preserves the published Session, and successful publication advances the Session Epoch once.
- [ ] `HttpClient`, `StdHttpClient`, and `FakeHttpClient` support the tested two-request bound, request-keyed responses, controlled completion order, and active-request counts.
- [ ] Hermetic tests cover every supported completion order, required failures, Authenticated Account failure, stale intent, complete awaiting, stable assembly, and cleanup.
- [ ] A local Credential-free HTTP test proves that two calls overlap through one `StdHttpClient`, complete, and clean up.
- [ ] The opt-in gate alternates ten sequential and ten bounded complete loads for PullRequests 1856 and 1726. It records median latency, connection count, failures, and 429 responses without Credential data.
- [ ] Bounded acquisition lands only if both PullRequests improve by at least 30 percent, use at most two connections, and produce no failure or 429 response.
- [ ] If the live gate fails, production remains sequential and all dormant fan-out code is removed. The ticket records the no-go evidence.
