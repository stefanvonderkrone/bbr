# External dependencies sit behind swappable seams

The three external-facing dependencies — the HTTP client, the pending-review store, and the
syntax highlighter — are each accessed only through a narrow interface (vtable erasure, the
same idiom as `std.mem.Allocator`). Concretely: `HttpClient` (`std.http.Client` now, libcurl
later), `PendingReviewStore` (SQLite/libSQL now), and `Highlighter` (plain now, tree-sitter later).

## Why

- **std.http.Client** covers the common proxy case (env-var autoload, CONNECT tunneling,
  Basic-auth proxies) with zero C dependencies, but *cannot* handle NTLM/Kerberos or
  TLS-intercepting corporate proxies. If check24's network turns out to need those, libcurl
  swaps in behind the seam without touching the Bitbucket adapter.
- Every seam has a **fake implementation** (canned JSON, in-memory store, no-op highlighter),
  which is what makes the domain logic — diff parsing, thread building, submission ordering,
  failure handling — testable with no network, no disk, and no C toolchain. This is the
  backbone of the TDD approach.

## Consequences

Callers depend on the interface by value; the concrete implementation is chosen at one
construction site (or a `build.zig` option). Swapping any of the three is a localized change.
