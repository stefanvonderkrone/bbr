# Reuse HTTP connections

Type: task
Status: resolved
Blocked by: 22

## Question

If Action 23 passes the P2 gate, how will one shared HTTP connection pool and concurrent File-side fetches preserve request bounds, Session Epoch safety, and visible rate-limit behavior?

## Answer

`openTui` now keeps one `StdHttpClient` from startup through TUI shutdown. Every remote worker uses the same Bitbucket `Client`, so requests can reuse the same connection pool. The pool uses `page_allocator`, which is safe for concurrent `std.http.Client` calls.

Remote File Enrichment starts both present sides concurrently and waits for both outcomes. One File starts at most two requests. Added and removed Files still start one request, and LocalReview File Enrichment stays sequential. A failed inner worker launch falls back to the sequential path.

Presentation still checks the Session Epoch when it receives the complete File Enrichment result. Both side tasks finish and clean up before that result crosses the worker boundary. The Bitbucket adapter still exposes `RateLimited` as each side's typed fetch failure, and submission requests keep their existing `Retry-After` handling.

[Select P2 actions from the post-P1 profile](22-select-p2-actions.md) measured a 30% to 40% live acquisition latency reduction with two active requests and no failures or rate limits. The deterministic File Enrichment check now proves that both sides overlap and that one File uses exactly two active requests. `zig build test --summary all` passes all 710 tests. A new live run was unavailable because the current process lacked the Bitbucket username.
