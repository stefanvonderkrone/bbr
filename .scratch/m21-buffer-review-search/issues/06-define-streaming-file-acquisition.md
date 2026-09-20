Type: grilling
Status: open
Blocked by: 04, 09

# Define Streaming File Acquisition

## Question

How should Review Search acquire and search both complete File versions without blocking input or bypassing File Enrichment policy?

Define when acquisition starts, its concurrency bound, reuse of loaded content, the File cache budget, and publication order. Define per-File and per-version loading, absent, binary, invalid UTF-8, and failure states. Define Session Epoch rejection, cancellation or completion of stale work, Overlay closure, remote and local parity, and safe ownership of streamed results.

## Comments

- Review Search starts File Enrichment when the Overlay opens. It scans Files by full `File.displayPath()` order.
- Acquisition is independent from the query. The UI thread updates query input. One scan worker coalesces queued work to the latest query generation and rejects stale results without a fixed debounce.
- Review Search uses bounded streaming instead of a complete Session search index. It rescans cached content, reuses in-flight acquisition, and reacquires evicted content when a later query needs it.
- A scan temporarily protects one File from LRU eviction. Normal `[files.cache]` enforcement resumes after the scan. Search Occurrences do not copy every matching source Line. Selecting a Preview can reacquire evicted content.
- The Overlay shows per-version acquisition state immediately. Selectable source occurrences wait until all present versions of a File finish, so old/new coalescing publishes stable identities.
- While Review Search is open, its acquisition has priority over focused File demand. Running work completes, and one-successor prefetch pauses.
- Closing the Overlay stops queued acquisition. Running File Enrichment completes into the normal cache. Reopening resumes in full-path order.
- Remote transport, `429`, and `5xx` failures get one automatic retry. The retry honors `Retry-After`. Definitive remote and local failures do not retry.
- [Benchmark Review Search File Concurrency](09-benchmark-review-search-file-concurrency.md) must select separate remote and local File concurrency limits before this decision can resolve.
