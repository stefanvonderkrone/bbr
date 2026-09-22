# 15 — Eliminate Remaining Buffer Search Input Stalls

**What to build:** Buffer Search input remains responsive on large Pull Requests while opening search, typing rapidly, admitting scan completions, revealing hidden matches, and projecting highlights.

**Blocked by:** 11 — Add Buffer Search.

**Status:** ready-for-agent

- [ ] Add deterministic large-Buffer benchmarks that separately measure opening `/`, query-edit dispatch, worker scanning, completion admission, disclosure rebuilding, range projection, and painting.
- [ ] Record median and p95 latency plus fixture size before changing the implementation, and identify which synchronous stages cause the observed stalls.
- [ ] Query-edit dispatch performs bounded work and never builds the corpus, scans Candidates, clones a complete Batch, rebuilds disclosures, or projects all ranges.
- [ ] Corpus construction is cached, incrementally maintained, or performed as correlated worker work so opening `/` does not stall the terminal loop.
- [ ] Presentation allows at most one Buffer Search scan to consume worker capacity at a time and retains only the newest queued Query generation.
- [ ] Completion admission avoids an unbounded full-Batch clone on the terminal thread. Expensive disclosure and range projection work is staged without publishing a partial Frame.
- [ ] Command id, Session Epoch, and Query generation reject stale work. Cancellation, refresh, Review switching, shutdown, launch failure, and allocation failure release every Query, corpus reference, Batch, and staged projection.
- [ ] `Enter` while work is pending accepts only the newest completed generation. `Esc`, `n`, `N`, Count, active-occurrence retention, hidden-match reveal, and status reset keep their existing behavior.
- [ ] Presentation and runtime tests cover rapid edits before and after worker launch, stale completion ordering, cancellation, failure, and Session replacement.
- [ ] The benchmark demonstrates materially lower p95 input latency on the large fixture, and `zig build test --summary all` passes.
