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
- [x] Over the budget, the cache updates during a Review Search do not cost one full Buffer build for each released File. A Presentation test counts them and fails on commit `6f2917c7`.
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

`docs/rules/` does not exist on `main` yet. The coalesced cache update round put the rule into the rule table of `AGENTS.md`. This is the rule text for `docs/rules/`:

> A Buffer build that a background stream requests (File Enrichment results, Review Search lease and hold releases) has at most one queued build of its kind. A new request joins the queued build and keeps its place. `takeCommand` gives the build a new snapshot through `refreshQueuedBuild`. The one exception: a new Review Search source scan moves the queued cache update behind it while `Storage.cachePressure` is not `far_over_budget`. Enforcement: the switch in `refreshQueuedBuild` names every `DisclosureBuild.Kind` (compile error for a new kind), and the tests "a stale enrichment rebuild gives its results to the one queued rebuild", "M21 kernel Review Search source scans evict the Files they release while the query changes", and "M21 kernel Review Search source scans over the cache budget share their cache updates".

### Checks

- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.

## Coalesced cache updates

The first fix had a cost.
Over the budget, each File that a source scan released asked for a cache update, and the queued cache update ran before the next scan.
A cache update is a full Buffer build, so each released File cost one build.
On a large Review over the budget, about 0.3 s for each build could add up to minutes of CPU. This is an estimate. No run measured it.

### Options

The bounds are for the time while the source scans run. Every option keeps the m21 invariant, because the cache update still publishes the cache content, the cache focus, and the Frame together. Every option ends within the budget when the scans stop.

| Option | Memory over the budget while the scans run | Cache updates for each pass over the Files |
| --- | --- | --- |
| A. The cache update waits while a source scan is queued. It runs when the scans stop. | Every File the pass releases, up to the whole Review, for the whole pass. | One for each stop. A stop waits for File Enrichment or a query, so the count is at most the enrichment builds plus the query edits plus one. |
| B. The cache update waits until the inactive Files are far over the budget: more than twice the budget, held in at least an eighth of the Files or in 64 MiB. It also runs when the scans stop. | At most the larger of twice the budget and 64 MiB, plus the one File that crosses the threshold. With small Files, the eighth of the Files stops it much earlier. | Each cache update evicts more than a budget of bytes. With Files of one size, it also evicts more than a sixteenth of the Files. So the count is at most the released bytes divided by the budget, plus the stops. With Files of one size, it is also at most 16 plus the stops. |
| C. Enrichment builds evict the released Files on admission. A cache update runs only when no File Enrichment is in flight. | Every File the pass releases after the last enrichment build. When every File is already enriched, this is the whole Review. | At most one for each stop, as in A. Needs a signal for in-flight File Enrichment and a check after a failed fetch. |

A probe of option A on the 40-File run below gave 1 cache update, but 39 inactive Files stayed in memory while the scans ran.
That is the whole Review, so option A only moves the fault to the end of the pass.
Option C has the same bound when no File Enrichment is in flight, and it needs more signals.

### Pick

Option B. It bounds the memory in bytes and the CPU in full Buffer builds.
The threshold needs more than twice the budget and one of two amounts: an eighth of the Files or 64 MiB.
Twice the budget alone degenerates when the budget is smaller than one File: then each release crosses it, and each File costs a build again.
An eighth of the Files alone has no bound in bytes. A few large Files never reach it.
64 MiB alone keeps a small Review over a small budget for the whole pass. M28 S5 would then likely see no refetch (inferred, not run).
The first version had only the eighth of the Files. The Spec review found the gap in bytes, and commit `0d38f1f3` added the 64 MiB condition.
Option B also keeps the enrichment fold of option C: an enrichment build that runs between two scans evicts on admission.

`Storage.cachePressure` in `src/tui/file_enrichment.zig` returns `within_budget`, `over_budget`, or `far_over_budget`.
`maybeQueueReviewSourceScan` in `src/tui/presentation.zig` moves the queued cache update behind the new scan unless the pressure is `far_over_budget`.
A request for a new cache focus joins the queued cache update. While the scans run, the scan moves that update too. So a focus change while Review Search is open waits until the scans stop or the cache is far over the budget. `ensureFocusedEnrichment` also waits for it before `focusAdmitted`. The Overlay close is not affected, because no scan follows it.
The move puts the cache update at the end of the queue, also behind commands that came after it. Its snapshot is new at take, so the order does not change its result.

### Bound

While the source scans run, the inactive bytes stay at or below the larger of twice the budget and 64 MiB, plus one File.
With Files of one size, they also stay below the larger of twice the budget and an eighth of the Files, plus one File.
The excess lasts until the next cache update commits, which is at the latest when the scans stop for File Enrichment, a query, or the end of the Files.
Then the cache update reaches the front of the queue and brings the cache within the budget, before the Overlay closes.

### Numbers

A Presentation run over 40 Files, with the query `new` and two query edits, in queue order (80 source scans):

| Budget | Side | Enrichment builds | Cache updates | Most inactive Files while scans run |
| --- | --- | ---: | ---: | ---: |
| 1 byte | `6f2917c7` | 11 | 77 | 1 |
| 1 byte | this fix | 10 | 12 | 5 |
| 4 Files (2432 bytes) | `6f2917c7` | 9 | 65 | 5 |
| 4 Files (2432 bytes) | this fix | 9 | 11 | 9 |
| unlimited | both | 5 | 0 | 39 |

The run is deterministic, so one run of each row is enough.
The earlier table above counted a run with 60 scans, so its numbers differ.

The test "M21 kernel Review Search source scans over the cache budget share their cache updates" runs this case with both budgets.
On `6f2917c7` it fails at the count: 65 cache updates against the bound of 32.

### M28

A throwaway merge of this branch into `m28-full-review-file-cache-evaluation` passes `zig build test-file-cache`. Two runs gave the same S4 and S5 numbers.

| Scenario | Side | refetches | requests | enrichments | peak_retained_bytes | retained_bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| S4 | before `ae39a66d` | 1 | 12 | 5 | 6744 | 6744 |
| S4 | this fix | 1 | 12 | 5 | 8308 | 6744 |
| S5 | before `ae39a66d` | 3 | 7 | 6 | 6744 | 5280 |
| S5 | this fix | 3 | 6 | 6 | 8308 | 6744 |

The M28 fixture has 6 Files and a one-byte budget, so one released File is an eighth of the Files and far over the budget.
The cache update keeps its place there, as in the first fix, and the numbers do not change.
The run was before commit `0d38f1f3`. That commit adds only the 64 MiB condition, and the whole fixture Review is 8308 bytes, so the numbers cannot change (inferred, not run again).

### Commits

- `d1e23a91` tui: test that Review Search scans share their cache updates
- `0f55293a` tui: let Review Search scans pass the cache update until far over
- `0d38f1f3` tui: bound the bytes that Review Search scans keep over the budget

The rule is the section [Coalesced Buffer builds](../../../docs/rules/tui-state.md#coalesced-buffer-builds). Its unchecked part is a section in `CODING_STANDARDS.md`.

### Review

The Standards review asked for the rule-table shape of `docs/agents/rule-details.md` and for names. The row and its details section follow it.
The Spec review found the gap in bytes and the focus change that waits for the scans. Commit `0d38f1f3` closes the gap. This ticket records the wait.
Open: the eighth of the Files and 64 MiB are judgement values. No run on a large Review measured them. The section "Live test fixes" replaces them with a byte limit.

### Checks

- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.

## Comments

## Live test fixes

A live test on the local Review `fb701b11..18362616` (479 Files, 22.6 MiB of File content, 187,827 rows) found three problems. Each fix has a failing test commit before it.

### Memory after the Overlay closes

Over the budget, the branch kept 13.4 to 14.1 GB after Review Search closed in 6 of 7 runs. `main` kept 8.3 to 8.5 GB.

Cause: the accepted Buffer build stays alive as `Published.worker_frame`, because its arena holds the Buffer. It also kept its Review Search snapshot, a retained `search.Batch`. Each source scan replaces the Batch, so the Frame became the only owner of the old Batch until the next Buffer build. On `main` the cache updates ran at the end of the scans, so the last snapshot was the final Batch. Here they run while the scans run, so the last one keeps a late Batch.

Fix: `acceptBufferDisclosure` releases the snapshots when the build becomes the published Frame (`DisclosureBuild.releaseSnapshots`).

- `3ef48837` tui: test that the published Frame keeps no replaced search Batch
- `d916df00` tui: release the search snapshots of the published Frame

Live, 1 MiB budget, physical footprint after close, after 30 s, and after 3 × `]` and 20 × `j`:

| Side | Run | After close | After 30 s | After navigation |
| --- | --- | ---: | ---: | ---: |
| before | 1 | 8.4 GB | 8.4 GB | 8.4 GB |
| before | 2 | 8.5 GB | 8.5 GB | 8.5 GB |
| before | 3 | 14.3 GB | 14.3 GB | 8.5 GB |
| fix | 1 | 8.5 GB | 8.5 GB | 8.5 GB |
| fix | 2 | 8.4 GB | 8.4 GB | 8.4 GB |
| fix | 3 | 8.5 GB | 8.5 GB | 8.5 GB |

The four 1 MiB and 8 MiB runs of the byte limit below also end at 8.4 GB.

### Preview stuck on "Reacquiring File content…"

A selection move during the scans showed "Reacquiring File content…" in the Preview within 1 to 4 s, and it stayed until the next selection move. `main` showed it when the scans ended.

Cause: no event republishes the Preview, because nothing reacquires the File. The selected File had no lease and was outside the cache focus, so a cache update evicted it like any File that a scan released. Only `selectReviewSearch` acquired a pending File again.

Fix: Presentation holds the File of the selected source occurrence while the Overlay shows it (`ReviewSearchState.preview_held`). `holdReviewSearchPreview` runs after each dispatch, moves the hold when the selected File changes, and acquires the File again when it was evicted before the selection reached it. `Published.releaseReviewSearchHolds` releases the hold.

- `70b2c7c5` tui: test that the Review Search Preview keeps its File content
- `6bd68cb6` tui: hold the File that the Review Search Preview shows

The test fails for a one-byte budget (eviction while the scans run) and for a budget of thirty Files (eviction when they end). "M21 authored opening evicted source waits for exact File Enrichment" evicted the selected File while the Overlay was open, so it now closes the Overlay to evict it and opens it again.

Live, C-d 3 s after typing `e`, then 15 s after the scans stop: before, 1 of 1 run showed "Reacquiring File content…" from about 10 s to the end. With the fix, 3 of 3 runs (two at 1 MiB, one at 8 MiB) never showed it.

A hold changes `Storage.revision`, so a selection move to another File during a running build makes that build retry. The live runs, which move the selection every 2 s, had 5 retries instead of 2.

### Byte limit

The eighth of the Files let 24 to 28 large Files hold ten times a 1 MiB budget, and the 64 MiB clause never acted on a 22.6 MiB Review.

Now far over the budget means that the inactive Files exceed the budget by more than the larger of the budget and `Storage.far_over_budget_floor` (4 MiB). Each cache update while the scans run frees more than that excess, so the scans cost at most one full Buffer build for each excess that they release. Twice the budget keeps that ratio for a large budget. The floor keeps a budget smaller than one File from costing a build for each released File. On the local Review, 4 MiB gave fewer cache updates than the old rule at 1 MiB, and the same at 8 MiB.

- `1c4d6cb2` tui: test a byte limit for the cache updates of Review Search
- `3ae9b944` tui: limit the bytes over the budget that Review Search scans keep

Deterministic Presentation run, 40 Files, 80 source scans, two query edits, one-byte budget. One run of each row, because the run is deterministic.

| File size | Rule | Cache updates | Peak inactive bytes |
| --- | --- | ---: | ---: |
| 1.18 MB | old | 12 | 5,906,220 (5 Files) |
| 1.18 MB | byte limit | 16 | 4,724,976 (4 Files) |
| 608 B | old | 12 | 3,040 (5 Files) |
| 608 B | byte limit | 1 | 23,712 (39 Files) |

The limit allows 1 B + 4 MiB + one File, 5,375,549 bytes, for the large Files. The old rule fails it. Small Files stay below the floor, so the cache update waits for the end of the scans and the budget holds from there.

Live, ReleaseFast, tmux 160×80, query `e` then `ee`, two runs on each side. Peak inactive bytes and cache updates come from an instrumented copy that prints a line for each accepted scan and each accepted cache update. CPU is the process CPU time after the load.

| Budget | Side | Peak inactive MiB | Cache updates | Retries | CPU s | Scan `e` / `ee` s |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 MiB | before | 16.35, 16.45 | 14, 15 | 5, 5 | 33.3, 34.2 | 16.1 / 13.9, 17.1 / 13.8 |
| 1 MiB | byte limit | 12.22, 12.17 | 10, 10 | 3, 3 | 36.7, 38.7 | 19.1 / 15.0, 20.2 / 16.1 |
| 8 MiB | before | 16.26, 16.26 | 2, 2 | 5, 4 | 33.0, 25.9 | 13.3 / 16.4, 15.1 / 11.4 |
| 8 MiB | byte limit | 16.27, 16.26 | 3, 2 | 4, 4 | 31.6, 27.1 | 14.1 / 14.8, 13.5 / 10.7 |

"Before" is `6bd68cb6`, which has the first two fixes. The 1 MiB peak with the byte limit is one File of about 7 MiB on top of the limit. Without it, the inactive bytes stay at about 5 MiB.

The CPU time at 1 MiB goes up by 3 to 4 s although the cache updates go down. In the first pass of one run on each side, the old rule fired five cache updates at up to 54,000 occurrences and one at the end. The byte limit fired four at 37,000 to 149,000 occurrences and one at the end. A `sample` of 3 s during the first pass puts most of the active main thread time in `__munmap` and `__mmap` under `search.Batch.deinit` and `search.Batch.clone`, also under `DisclosureBuild.destroy`. So a cache update costs more when the Batch is larger. The cost of one cache update depends on the Batch, which no limit in bytes of File content controls. [Review Search Batch memory ticket 01](../../review-search-batch-memory/issues/01-find-why-review-search-holds-gigabytes.md) has the clone.

M28 was not run again. Its fixture holds 8,308 bytes, below the floor, so a cache update there now waits for the end of the scans or a query, as option A in the table above. The S5 query edits wait for each search to end, so S5 likely still refetches (inferred, not run).
