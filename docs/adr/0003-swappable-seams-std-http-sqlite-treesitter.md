# External dependencies sit behind swappable seams

The HTTP client, the pending-review store, and the syntax highlighter each use a narrow
interface. The interfaces use the same vtable-erasure form as `std.mem.Allocator`.
The interfaces are `HttpClient`, `PendingReviewStore`, and `Highlighter`.

## Why

- `std.http.Client` loads standard proxy environment variables. It supports CONNECT tunnels
  and Basic proxy authentication without a C dependency.
- The representative corporate environment needs no proxy, proxy authentication, or TLS
  interception. A live `StdHttpClient` check reached Bitbucket Cloud through direct HTTPS.
  A libcurl adapter would add a C dependency without meeting a measured requirement.
- `std.http.Client` does not support proxy bypass lists, NTLM, or Kerberos. A future measured
  requirement for one of these features can replace `StdHttpClient` behind `HttpClient`.
- The Candidate Session live gate passed with two active requests. `HttpClient` therefore permits
  concurrent `send` calls up to the caller's fixed bound. One `StdHttpClient` owns the shared
  connection pool for one Candidate Session attempt.
- Every seam has a **fake implementation** (canned JSON, in-memory store, no-op highlighter),
  which is what makes the domain logic — diff parsing, thread building, submission ordering,
  failure handling — testable with no network, no disk, and no C toolchain. This is the
  backbone of the TDD approach.

## Consequences

`StdHttpClient` is the only production `HttpClient` adapter. It rejects invalid or unsupported
proxy configuration before a request and never retries through a direct connection.

Remote Candidate Session acquisition uses at most two active requests. This limit is not
configurable. Every started request completes before the adapter or branch-owned data is destroyed.

Callers depend on each interface by value. Production chooses each implementation at its
construction site. `HttpClient` remains the replacement boundary for a future measured need.
