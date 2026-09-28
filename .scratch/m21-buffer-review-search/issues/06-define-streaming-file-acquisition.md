Type: grilling
Status: resolved
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

## Answer

### Acquisition and priority

Opening Review Search starts File Enrichment for the complete Review. Acquisition does not wait for a nonempty query and does not restart when the query changes. It visits Files in ascending `File.displayPath()` order, with Diff File order as the stable tie-breaker.

Review Search uses the existing File Enrichment pipeline. It reuses cached content and joins in-flight work instead of issuing duplicate reads. It starts new work only for File content that is still pending or was evicted.

Both remote PullRequests and LocalReviews use a limit of eight Files. A modified remote File can read its old and new versions concurrently, so Review Search can use up to 16 remote requests. LocalReview acquisition can use up to eight Git processes. A retry keeps the same File slot.

While the Overlay is open, Review Search acquisition takes priority over new focused-File demand. Work that has started completes. One-successor remote prefetch pauses until the Overlay closes.

### Query scans and publication

The UI thread owns query input. One scan worker processes cached File content and ReviewBodies. Each query change increments a query generation. The worker drops queued scans for older generations and continues with the latest generation without a fixed debounce.

ReviewBody occurrences can publish as soon as the current query scan completes. A File publishes selectable source occurrences only after every present version reaches a terminal state. This File boundary lets Review Search coalesce Diff-proven unchanged old and new matches before publication.

Each File publication replaces that File's occurrences for the current query generation. Presentation then globally sorts all available occurrences by the contract in [Define Review Search Matching and Ordering](04-define-review-search-matching-and-ordering.md). Publication order and acquisition order cannot affect the final order. Presentation retains selection by Search Occurrence identity when a publication reorders the list.

The worker stamps every publication with both the Session Epoch and the query generation. Presentation rejects a publication when either value is stale.

### File content states

The Overlay exposes each old and new version independently. A version has one of these search states:

- `loading` while File Enrichment has started but has not produced a terminal state;
- `text` when valid UTF-8 content is available for scanning;
- `absent` when the File status has no such version;
- `binary`, with the byte size when known;
- `invalid UTF-8`, with the byte size;
- `unavailable` for a known non-acquisition reason, such as an invalid path;
- `acquisition failure`, with a classified reason suitable for display.

Only `text` contributes source occurrences. A terminal state on one version does not suppress usable content from the other version. The Overlay shows non-text and failure states as non-selectable rows after available occurrences.

Remote transport failures, `429` responses, and `5xx` responses get one automatic retry. A `429` retry honors `Retry-After`. Authentication, authorization, validation, missing content, and other definitive remote failures do not retry. Local acquisition failures do not retry.

### Cache and ownership

Review Search obeys `[files.cache]`. A scan pins one File until the worker finishes reading both versions and building that File's occurrence values. This scan pin is separate from the existing focused-File protection. The two protected Files can temporarily exceed the inactive-content budget.

After the scan releases its pin, normal LRU enforcement resumes. It can evict content from any inactive, unpinned File. A later query scan reacquires evicted content through File Enrichment. Selecting an occurrence can also reacquire content before it builds the Preview.

A streamed source occurrence owns its File identity, version relation, line coordinates, score, and UTF-8 ranges. It does not borrow source bytes from File Enrichment storage. This rule lets LRU eviction free File content without leaving dangling occurrence data. The Preview borrows content only while that content has an active cache or scan pin.

### Closure and Session replacement

Closing the Overlay stops queued search acquisition and query scans. File Enrichment that has started runs to completion and enters the normal Session cache when its Session Epoch is still current. Its completion does not publish search results into a closed Overlay.

Reopening Review Search resumes pending acquisition in full-path order. It reuses content and terminal states that remain in the Session cache. The state lifetime of the query and selection belongs to [Define Search Navigation and State Lifetime](07-define-search-navigation-and-state-lifetime.md).

Session replacement stops all queued work for the old Session Epoch. Started work can finish because the existing worker model does not cancel active branches. Presentation rejects its completion by Session Epoch and frees all owned content and occurrence values. Remote and local acquisition follow the same scheduling, state, cache, publication, and rejection contract. Only their File Enrichment adapters differ.
