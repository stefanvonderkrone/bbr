# The submit worker uses one arena for the whole batch and never resets it

`submitWorker` (src/tui/app.zig) builds a `StdHttpClient` and then POSTs each Draft in the
Submission batch. The client and every per-request allocation (JSON request bodies, parsed
responses, dedupe fetches) all share **one arena**, which is freed only when the worker returns.
The arena is **never reset mid-batch**.

## Why this is a real decision (and how it bit us)

An `StdHttpClient` keeps live buffers on the allocator it was built with — its connection pool
and proxy config outlive any single request. The first cut of the worker treated that arena as
per-request scratch and called `arena.reset(.retain_capacity)` after the stale-check and again
before each POST. That freed the client's live buffers; the next `send` used freed memory and
the process aborted (SIGABRT).

There are genuinely **two lifetimes** here:

- **client lifetime** — connection pool + proxy config, lives for the whole batch;
- **per-request scratch** — bodies and parsed responses, could be reclaimed after each POST.

The textbook shape is two allocators: a long-lived one for the client and a resettable arena for
per-request scratch, so per-request memory can be reclaimed mid-batch without touching the client.

## Why we chose one arena anyway

A Pending Review is a handful of Drafts (ADR-0002). Per-request memory that is not reclaimed
until the worker returns is therefore bounded and small. Splitting into two allocators buys
nothing at this scale and adds a second lifetime to reason about. We take the simpler shape and
accept that the arena grows with the batch.

## Consequences

- The worker's arena must **never** be reset while the client is alive — a comment at the
  declaration records this, and this ADR is the why behind it.
- If batches ever become large (bulk operations, importing reviews), revisit: the correct fix is
  the two-allocator split above, not re-introducing a reset on the shared arena.
- The pattern matches the other TUI workers (load, blob, picker), which likewise build a client
  on a page-allocator arena freed at worker exit.
