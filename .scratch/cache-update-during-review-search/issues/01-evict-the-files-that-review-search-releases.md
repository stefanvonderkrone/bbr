# 01: Evict the Files that Review Search releases while it is open

Status: resolved
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

- [x] A Presentation test opens Review Search with a one-byte budget, runs the scans in queue order, and edits the query. While the Overlay is open, the inactive Files are within the budget, and the published Frame and the cache agree. It fails on `main`.
- [x] "M21 kernel search lease release and Review Search hold release stage eviction once", "M21 authored opening evicted source waits for exact File Enrichment", and "M21 kernel cache Frame launch failure and closed sink preserve content and focus" pass unchanged.
- [x] M28 `zig build test-file-cache` passes after a merge of the fix. S4 and S5 are reported against the pre-merge numbers.
- [x] The number of full Buffer builds during a Review Search does not go back to the cascade.
- [x] `zig build test` passes.

## Completion

Commits on branch `cache-update-during-review-search`:

- `1eaadeaa` tui: test that Review Search evicts the Files it releases
- `3127762c` tui: keep the queued cache update in place and refresh it at take

### Change

The cache update follows the two rules of the enrichment build.
At most one cache update waits in the queue, and a new request keeps its place and changes only its focus (`queueCacheBuild`).
`takeCommand` gives the cache update a new snapshot when a worker takes it (`refreshQueuedBuild`, which replaces `refreshEnrichmentBuild`).
The switch in `refreshQueuedBuild` names every build kind, so a new kind needs a decision.
The cache update still publishes the cache content, the cache focus, and the Frame together, so the m21 invariant holds.

Each rule alone leaves the new test red.
With the snapshot rule only, the cache update stays behind the next source scan.
With the place rule only, the new test and "M21 kernel cache focus supersedes queued and issued focus changes" fail.

### Tests

- "M21 kernel Review Search source scans evict the Files they release while the query changes" runs the queued work in order with a one-byte budget, edits the query, and checks the budget and the agreement of the Frame and the cache while the Overlay is open.
  On `main` it fails at the first budget check. The queue was `scan_review_source, cache_update` after three scans.
- The three m21 tests that option C broke pass unchanged.

### M28

A throwaway merge of this branch into `m28-full-review-file-cache-evaluation` passes `zig build test-file-cache`.
Two runs gave the same S4 and S5 numbers.

| Scenario | Side | refetches | requests | enrichments | peak_retained_bytes | retained_bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| S4 | before `ae39a66d` | 1 | 12 | 5 | 6744 | 6744 |
| S4 | `main` | 1 | 12 | 5 | 8308 | 8308 |
| S4 | this fix | 1 | 12 | 5 | 8308 | 6744 |
| S5 | before `ae39a66d` | 3 | 7 | 6 | 6744 | 5280 |
| S5 | `main` | 0 | 0 | 0 | 8308 | 8308 |
| S5 | this fix | 3 | 6 | 6 | 8308 | 6744 |

The S4 peak stays at 8308, because one batched admission holds every File of the batch before the first scan releases one.

### Build count

A temporary Presentation test, not committed, ran a Review Search on 40 Files with 60 source scans and two query edits, in queue order.

| Budget | Side | Enrichment builds | Cache update builds | Rejected builds |
| --- | --- | ---: | ---: | ---: |
| 1 byte | `main` | 6 | 2 | 1 |
| 1 byte | this fix | 7 | 57 | 0 |
| 256 MiB (default) | `main` | 5 | 0 | 0 |
| 256 MiB (default) | this fix | 5 | 0 | 0 |

No build is rejected, so the cascade does not come back.
Over the budget, each File that a scan releases costs one committed Buffer build, because the m21 invariant needs a new Frame for each eviction.
Under the default budget, nothing changes.
The live run on the large local Review was not done, because its Files stay far below the default budget, so no cache update is queued there.

### Review

The two-axis review found no violation of a documented standard and no gap in the criteria.
It found that the in-place lookup matched only the current Session, so a cache update of an earlier Session could stay queued. The append path now removes it, as before.
It also found that a release during a running cache update makes that run stale. The retry joins the queued cache update, so the waste is one run for each release during a run. The serial build count above cannot show it.
[Ticket 02](02-refresh-every-queued-buffer-build-at-take.md) records the other build kinds that still take their snapshot when they are queued.

### Rule for `docs/rules/`

`docs/rules/` does not exist on `main` yet. This is the rule text for it:

> A Buffer build that a background stream requests (File Enrichment results, Review Search lease and hold releases) has at most one queued build of its kind. A new request joins the queued build and keeps its place. `takeCommand` gives the build a new snapshot through `refreshQueuedBuild`. Enforcement: the switch in `refreshQueuedBuild` names every `DisclosureBuild.Kind` (compile error for a new kind), and the tests "a stale enrichment rebuild gives its results to the one queued rebuild" and "M21 kernel Review Search source scans evict the Files they release while the query changes".

### Checks

- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.

## Comments
