# File Enrichment transfers ownership independently per side

File Enrichment is a deep Presentation module that owns fetching, Highlighting outcomes, worker-result cleanup, and the Session's File-indexed enrichment storage. Each old/new side is single-assignment and transfers its owned blob, Spans, and Capture names into the Session without copying; the sides commit independently so failure on one never suppresses usable content from the other.

Presentation continues to own worker scheduling and stale-Epoch rejection because only it knows which Session is visible. A successful fetch remains usable when Highlighting fails, Diff Buffer construction receives only a borrowed immutable projection, and `OutOfMemory` transfers nothing, tears down cleanly, and exits with a distinct File Enrichment message. This shape was chosen over Session-arena deep copies and File-wide atomicity to concentrate ownership invariants, avoid duplicate allocations, and make allocation failure testable through one seam.

File Enrichment retains content under a configurable byte-budgeted LRU rather than for the entire Session. Old and new sides keep independent ownership and failure outcomes, but one File is the unit of recency, eviction, and refetch: its cache cost is the sum of both available payloads. `[files.cache]` exposes `enabled` and `max_retained_bytes_per_review`; caching defaults on with a 256 MiB budget for inactive content. The budget measures each owned side arena's retained allocation capacity—including blobs, Highlight Spans, Capture names, and retained scratch—but excludes the allocator's own linked-list bookkeeping. Disabling the cache retains only the focused File. The focused File is always usable and may exceed the budget, so there is deliberately no per-File content-size limit. The separate 2 MiB Highlighting limit still bounds parsing work, so large content remains readable as plain text without being parsed.

A same-Session completion that arrives after focus moved becomes the least-recently-used inactive File when caching is enabled and is discarded when caching is disabled. If focus returned before completion, it is admitted as active. Session replacement continues to reject it through the existing Session Epoch rule.

## Considered options

- Session-lifetime retention was rejected because retaining every fetched blob remains proportional to the review size.
- A hard per-side limit was rejected because arbitrarily large Files must remain reviewable.
- Byte-budgeted LRU bounds inactive retained content while preserving access to every File; its costs are a refetch when an evicted File is revisited and an active working set that may exceed the cache budget while a large File is focused. Per-version eviction was rejected because focus and fetch both operate on a whole File; partially cached Files would complicate refetching and produce asymmetric WholeFile fallback.
- A disk-backed cache could avoid network refetches without retaining all content in memory, but its storage and invalidation policy are deferred rather than coupled to the in-memory retention change.
