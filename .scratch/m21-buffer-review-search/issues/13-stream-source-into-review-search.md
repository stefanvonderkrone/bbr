# 13 — Stream Source into Review Search

**What to build:** Review Search streams fuzzy Search Occurrences from both complete versions of every changed File while input stays responsive. It reuses File Enrichment, reports each version state, respects the File cache budget, and behaves the same for RemoteReview and LocalReview.

**Blocked by:** 12 — Add Authored Review Search.

**Status:** ready-for-agent

- [ ] Opening Review Search starts complete-Review File Enrichment in display-path order, even for an empty Query.
- [ ] Review Search reuses cached and in-flight File Enrichment and starts at most eight Files at once. RemoteReview uses at most 16 side requests, and LocalReview uses at most eight Git processes.
- [ ] Search acquisition takes priority over new focused-File demand while the Overlay is open. Started work finishes, and one-successor remote prefetch pauses.
- [ ] One automatic retry covers remote transport, rate-limit, and server failures in the same File slot. A rate-limit retry honors normalized `Retry-After` evidence.
- [ ] Authentication, authorization, validation, missing content, other definitive remote failures, and all local failures become terminal without retry.
- [ ] Every old and new version exposes loading, text, absent, binary, invalid UTF-8, unavailable, or acquisition-failure state. Known binary and invalid UTF-8 sizes remain visible.
- [ ] Usable text from one version remains searchable when the opposite version has a terminal non-text or failure state.
- [ ] One thread-safe File read lease exposes immutable old and new content and pins one File against eviction during a scan.
- [ ] A scan lease can coexist with focused-File protection and temporary budget excess. Lease release reapplies the normal inactive-content budget.
- [ ] Session destruction retires leased content. The final lease release frees retired content without reading Session state.
- [ ] Presentation runs one owned scan command at a time with command id, Session Epoch, Query generation, Query snapshot, partition identity, and either ReviewBody data or one File lease.
- [ ] Query edits retain only the newest queued generation without a fixed debounce. Every stale, rejected, closed, or replaced completion frees its Batch and releases its lease.
- [ ] A File becomes scannable after every present version reaches a terminal state. Its complete partition publishes atomically and then triggers one global rerank.
- [ ] Diff-proven unchanged old and new matches coalesce only when text and exact ranges agree. Changed or version-specific matches remain separate.
- [ ] Streamed source Search Occurrences own identity, score, Line coordinates, and ranges without retaining complete source Lines.
- [ ] Selection survives global reranking by Search Occurrence identity. If the identity disappears, selection keeps its prior list position and clamps.
- [ ] Source Preview shows complete path details, nearby Lines, exact fuzzy ranges, horizontal scrolling, and a reacquisition state when content was evicted.
- [ ] Closing the Overlay removes queued acquisition and scans. Started File Enrichment can enter the normal cache but cannot publish closed-search results. Reopening resumes from current cache states.
- [ ] Presentation, adapter, cache, and headless rendering tests cover limits, ordering, retry, version states, leases, stale work, closure, cache enforcement, and RemoteReview or LocalReview parity.
