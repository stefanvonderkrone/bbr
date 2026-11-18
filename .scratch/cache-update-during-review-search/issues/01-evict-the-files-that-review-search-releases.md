# 01: Evict the Files that Review Search releases while it is open

Status: claimed
Claimed by: worktree `/Volumes/Work/t3-code/cache-update-during-review-search`
Blocked by: none

## Summary

The File cache budget does not hold while Review Search is open.
A Review Search source scan releases the hold of each File after it scans it.
The m21 design then applies the inactive budget again ([m21 issue 06](../../m21-buffer-review-search/issues/06-define-streaming-file-acquisition.md): "After the scan releases its pin, normal LRU enforcement resumes").
On `main` at `f6378a45`, no cache update commits until the Overlay closes or the scans end.
So every File that Review Search reads stays in memory, also with a budget of one byte.

The M28 File cache evaluation shows it.
After a merge of `main`, its S5 scenario refetches no File, and S4 keeps every byte of the full Review.
Before commit `ae39a66d`, each File Enrichment admission evicted inline, and that hid the fault.
Commit `ae39a66d` coalesces File Enrichment rebuilds, so the admission of one batch holds every File of the batch.

## Cause

All paths are in `src/tui/presentation.zig` at `f6378a45`.

1. `maybeQueueReviewSourceScan` (:8767) queues the scan of the next File and takes its lease.
   Then it releases the hold of that File through `finishSearchLease` (:8803).
2. `stageReleasedSearchLeases` (:8813) calls `queueCacheBuild` (:10210).
   `queueCacheBuild` removes the queued `.cache_update` build and appends a new one at the end of the queue, behind the scan that step 1 queued.
3. The scan completes. `acceptReviewSourceScanned` releases its lease, and `queueCacheBuild` moves the cache update to the end again.
   Step 1 runs again for the next File, and the cache update is again behind its scan.
4. A cache update that does reach a worker is stale.
   Its snapshot is from the time it was queued, and each lease, hold, and release after that changes `Storage.revision`.
   A query edit also replaces the Review Search batch.
   `acceptViewBuild` (:9827, :9867) rejects the build, and `retryContentBuild` (:10167) appends a new full build.

So while the scans run, the cache update never commits.
A temporary print in the failing test showed the queue `scan_review_source, cache_update` after three scans, at the fourth cache update request.

## Mistake class

"A rejected update queues a full rebuild."
Case 1 was the File Enrichment rebuild cascade ([cascade ticket 01](../../enrichment-rebuild-cascade/issues/01-coalesce-file-enrichment-rebuilds.md)).
Its fix gave the enrichment build two rules: one queued build that keeps its place and takes each new request, and a new snapshot when a worker takes it.
Case 2 is the `.cache_update` build, which has neither rule.

## Constraints

- The m21 invariant ([m21 issue 15](../../m21-buffer-review-search/issues/15-eliminate-remaining-buffer-search-input-stalls.md), lines 413 and 417): cache content, cache focus, and the published Frame change together. A failure keeps the previous Frame and cache content.
- Option C, an eviction at once on hold release, breaks that invariant and three tests. It is out.

## Acceptance criteria

- [ ] A Presentation test opens Review Search with a one-byte budget, runs the scans in queue order, and edits the query. While the Overlay is open, the inactive Files are within the budget, and the published Frame and the cache agree. It fails on `main`.
- [ ] "M21 kernel search lease release and Review Search hold release stage eviction once", "M21 authored opening evicted source waits for exact File Enrichment", and "M21 kernel cache Frame launch failure and closed sink preserve content and focus" pass unchanged.
- [ ] M28 `zig build test-file-cache` passes after a merge of the fix. S4 and S5 are reported against the pre-merge numbers.
- [ ] The number of full Buffer builds during a Review Search does not go back to the cascade.
- [ ] `zig build test` passes.

## Comments
