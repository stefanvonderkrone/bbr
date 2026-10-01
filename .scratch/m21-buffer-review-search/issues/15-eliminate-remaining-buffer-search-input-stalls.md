# 15 — Eliminate Remaining Buffer Search Input Stalls

**What to build:** Buffer Search input remains responsive on large Pull Requests while opening search, typing rapidly, admitting scan completions, revealing hidden matches, and projecting highlights.

**Blocked by:** 11 — Add Buffer Search.

**Status:** resolved

- [x] Add deterministic large-Buffer benchmarks that separately measure opening `/`, query-edit dispatch, worker scanning, completion admission, disclosure rebuilding, range projection, and painting.
- [x] Record median and p95 latency plus fixture size before changing the implementation, and identify which synchronous stages cause the observed stalls.
- [x] Query-edit dispatch performs bounded work and never builds the corpus, scans Candidates, clones a complete Batch, rebuilds disclosures, or projects all ranges.
- [x] Corpus construction is cached, incrementally maintained, or performed as correlated worker work so opening `/` does not stall the terminal loop.
- [x] Presentation allows at most one Buffer Search scan to consume worker capacity at a time and retains only the newest queued Query generation.
- [x] Completion admission avoids an unbounded full-Batch clone on the terminal thread. Expensive disclosure and range projection work is staged without publishing a partial Frame.
- [x] Command id, Session Epoch, and Query generation reject stale work. Cancellation, refresh, Review switching, shutdown, launch failure, and allocation failure release every Query, corpus reference, Batch, and staged projection.
- [x] `Enter` while work is pending accepts only the newest completed generation. `Esc`, `n`, `N`, Count, active-occurrence retention, hidden-match reveal, and status reset keep their existing behavior.
- [x] Presentation and runtime tests cover rapid edits before and after worker launch, stale completion ordering, cancellation, failure, and Session replacement.
- [x] The benchmark demonstrates materially lower p95 input latency on the large fixture, and `zig build test --summary all` passes.

## Remaining work

The original checklist is complete, but the following input-latency work remains. This list reflects the current code, not superseded progress notes.

- [x] Bound worker handoff cost. `DisclosureBuild.create` retains cached inputs and disclosure keys. The worker copies private File Enrichment tables and applies bounded disclosure changes. Handoff does not copy the complete PendingReview, ScopeProjection, Directory state, or File lease table.
- [x] Stage new Draft Buffer builds on a worker. TempId reservation precedes the worker build. Persistence succeeds before PendingReview, ScopeProjection, Composer closure, and the complete Frame publish together.
- [x] Stage Draft mutation Buffer builds on a worker. Cover body edits, re-anchor, Draft subtree deletion, and unresolved-outcome repair. Preserve persistence and Frame rollback.
- [x] Stage the remaining view-change Buffer builds. Layout, Scope, Selected Version, File isolation, isolated File movement, and width changes use workers for every Session size. Resolved visibility keeps its worker disclosure path. Width changes also use workers while Buffer Search input is open.
- [x] Remove Sidebar-triggered full Buffer rebuilds. Directory expansion, Directory collapse, and active-File reveal update the File Tree without rebuilding unchanged DiffPane content. An unchanged reveal updates active flags and Sidebar scroll without an allocation.
- [x] Stage Review Search destination Buffer builds. Cover source occurrences, ReviewBody occurrences, and the second build that reveals a hidden Fold. `openReviewSearchOccurrence` queues a worker, including after File Enrichment publication.
- [x] Stage disclosure restoration when Buffer Search starts after Review Search. `openBufferSearch` retains the disclosure baseline and queues a worker. Query input stays open while restoration runs.
- [x] Stage File Enrichment cache-focus and lease-release Frame changes. Completion Frames already use workers, but `focusEnrichment`, `finishSearchLease`, and `releaseReviewSearchHolds` can rebuild synchronously after eviction. Keep cache changes and Frame publication atomic.
- [x] Index hidden Search Occurrence navigation and disclosure lookup. Frame construction indexes source coordinates, ReviewBody owners, Fold membership, disclosure rows, and inherited Draft disclosure chains. Hidden `n`, `N`, Count, Query clearing, and the scan-to-disclosure handoff use the indexes.
- [x] Bound active-occurrence retention and origin selection during completion admission. Worker projection builds sorted occurrence-identity indexes and navigation prefix maxima and suffix minima. Completion admission and inactive traversal use binary lookup instead of complete Batch walks.
- [x] Bound navigation restoration during worker Frame admission. Worker Frames build owner and source-span navigation indexes. Admission restores the cursor, Selection, saved Buffer Search navigation, and origin through indexed lookup. Workers choose Selected Version and Draft deletion destinations. File-header navigation uses binary lookup.
- [x] Measure initial Session publication separately. Candidate Session preparation now builds the initial Buffer, visual rows, File Tree, source-coordinate projection, search indexes, and search corpus on a worker. Terminal admission publishes the complete Candidate Session.
- [x] Remove reachable synchronous search rebuild fallbacks after the paths above use workers. Production dispatch uses worker Frames. Synchronous Buffer builds and scans remain compile-time-guarded benchmark controls and test references. Transition and failure tests cover scan admission, Query clearing, and Escape.
- [x] Extend the latency benchmark and record final evidence. Cover many Draft bodies, many ReviewCards, nested Directories, cache eviction, hidden occurrence traversal, and resize during pending input. Measure worker handoff and navigation restoration separately. Record fixture sizes, median latency, and p95 latency. Run `zig build test --summary all` after the implementation changes, then update this checklist and the ticket status.

## Progress

Commits `4b967b3` and `72a7f35` serialize scans, transfer the worker Batch without a full clone, cache the corpus, and index source rows for range projection. The large-Buffer benchmark runs with `zig build bench-buffer-search`. The full suite passed with 833 tests.

The original work caches the corpus, serializes scans, reuses completed Batches, and indexes source rows. Later changes cache Hunk emphasis per Session, project Buffer Search ranges on the scan worker, and stage Query-driven hidden-match Buffer builds on a worker. Completion admission now takes worker ranges directly, but disclosure admission and other Buffer rebuilds remain synchronous.

## Baseline

`zig build bench-buffer-search` on `4b967b3`, ReleaseFast, 16 Files, 4,096 changed Lines, 63,240 Diff bytes, nine samples. Values are nanoseconds. The disclosure measurement includes Buffer rebuilding and range projection. Painting is not yet measured.

| Stage | Median | p95 |
| --- | ---: | ---: |
| Open `/` | 7,635,584 | 8,654,375 |
| Query edit | 5,291 | 22,875 |
| Worker scan | 44,682,917 | 47,385,334 |
| Completion admission | 92,566,416 | 94,588,583 |
| Disclosure rebuild | 98,758,708 | 101,908,584 |
| Range projection | 90,738,625 | 142,183,125 |

Opening builds the corpus on the terminal thread. Completion admission and disclosure rebuilding both project the entire Batch. Range projection scans every visual row for each Search Occurrence.

The baseline preceded the painting stage in the benchmark. The current benchmark measures headless painting on a 100 × 30 screen.

## After corpus caching and indexed projection

Same fixture and nine samples, after caching the corpus with the staged Buffer and indexing source rows during projection:

| Stage | Median | p95 |
| --- | ---: | ---: |
| Open `/` | 13,667 | 66,541 |
| Query edit | 16,792 | 27,042 |
| Worker scan | 45,697,292 | 47,291,833 |
| Completion admission | 1,419,167 | 1,524,083 |
| Disclosure rebuild | 9,340,666 | 9,966,084 |
| Range projection | 463,417 | 490,208 |
| Headless painting | 55,125 | 81,958 |

The corpus cache moves its build cost to Session publication and Buffer rebuilding. Disclosure rebuilding still runs on the terminal thread. The benchmark uses a 4,096-Line fixture, so it does not set a bound for larger Sessions. The baseline has no painting sample.

## Disclosure rescan removal

On the same 16-File, 4,096-Line fixture, `zig build bench-buffer-search` measured disclosure rebuilding at 8,403,250 ns median and 10,118,125 ns p95 before Batch reuse. After Batch reuse, it measured 4,582,000 ns median and 4,996,583 ns p95. A disclosure changes visual rows but not Search Occurrences. The rebuild now projects existing Batches without scanning them again. A pending Query does not trigger a synchronous scan during a disclosure rebuild. The full suite passed with 839 tests.

The next work is to stage File Tree construction and the remaining Buffer Search range projection on the worker. Also stage `n`, `N`, Escape restoration, and general Buffer rebuilds without publishing a partial Presentation Frame.

## Bottom-origin admission

The benchmark accepts a Query from both the first and the last visual row. Pass a Line count per File with `zig build bench-buffer-search -- 512`. The default remains 128 Lines per File.

At 512 Lines per File, the fixture has 16 Files, 16,384 changed Lines, and 259,848 Diff bytes. Nine ReleaseFast samples measured a 5.42 ms p95 for bottom-origin completion admission. Query edits measured 18 µs p95. Disclosure rebuilding still measured 18.37 ms p95, and range projection measured 1.77 ms p95.

Completion admission now indexes visible source rows once when the Query starts below the first row. It avoids a scan of every visual row for each earlier visible Search Occurrence. Escape and an unchanged reveal skip Buffer rebuilding. Hidden-match disclosure rebuilding and range projection still run on the terminal thread. The ticket remains open.

## Reused Hunk emphasis

Presentation now computes Hunk emphasis once per Session and reuses it in subsequent Buffer and search-corpus builds. On the 16,384-Line fixture, `zig build bench-buffer-search -- 512` measured disclosure rebuilding at 18.37 ms p95 before the cache and 3.26 ms p95 after it. Both runs used nine ReleaseFast samples. The full suite passed with 842 tests.

The 32,768-Line fixture still measures 10.37 ms p95 for disclosure rebuilding and 4.29 ms p95 for range projection. Both run on the terminal thread. Session acquisition now computes Hunk emphasis before publication. Manual Session builders compute it at publication. The cache does not bound disclosure or range-projection work.

## Worker range projection

Each complete Frame now owns a reference-counted copy of its visual source coordinates. A Buffer Search command retains the copy. The scan worker projects ranges and occurrence navigation rows without reading the mutable Session or Buffer. Completion admission uses those results only if the Session Epoch and visual-row revision still match. If the Frame changed, admission projects against the current Buffer instead. Cancellation and Session replacement release the copy after the worker finishes.

On the 32,768-Line fixture, nine ReleaseFast samples measured 0.32 ms p95 for top-origin admission and 0.57 ms p95 for bottom-origin admission. Worker projection measured 4.78 ms p95. The `scan` stage includes worker projection, and the `worker_projection` stage measures that operation separately. Disclosure rebuilding still measured 8.66 ms p95. The full suite passed with 846 tests.

The remaining terminal work is disclosure Buffer construction, its visual-row snapshot, and reprojection after a Frame changes during a scan. The ticket remains open.

## Hidden-match Buffer staging

A hidden Buffer Search match now queues a disclosure build instead of rebuilding the Buffer during scan admission. The worker uses a retained Session, a copy of the Pending Review and ScopeProjection, and retained File Enrichment content. It builds the Buffer, visual rows, source-coordinate copy, and match ranges before completion. Presentation publishes them together only when the command id, Session Epoch, Query generation, Frame revision, and geometry still match. An edit or Escape drops queued builds. A changed Frame causes a new scan against the current Frame.

On the 16-File, 16,384-changed-Line fixture, nine ReleaseFast samples measured 18.50 ms p95 for worker Buffer construction and 2.13 ms p95 for completion admission. The separate hidden-match fixture has one File, 16,386 Lines, and 333,040 Diff bytes. It measured 7 µs p95 for Query edits, 4.26 ms p95 for worker construction, and 0.13 ms p95 for completion admission. The benchmark command is `zig build bench-buffer-search -- 512`. The worker now uses an arena for each literal scan Batch, so releasing an old Batch does not free every Search Occurrence on the terminal thread.

This path covers hidden matches selected from Query input and restores search-owned disclosures after later Query edits. `n` and `N`, Escape after a previous search-owned disclosure, and general Buffer rebuilds still construct a Buffer on the terminal thread. The ticket remains open.

The same hidden fixture measured Escape at 0.20 ms p95. Escape restores the collapsed Buffer synchronously. That measurement does not bound Escape on Sessions with many disclosed ReviewCards or Files.

At `zig build bench-buffer-search -- 1024`, the hidden fixture has 32,770 Lines and 677,104 Diff bytes. Nine ReleaseFast samples measured 7 µs p95 for Query edits, 8.71 ms p95 for worker construction, 0.39 ms p95 for completion admission, and 0.56 ms p95 for Escape.

A follow-up run measured the handoff from worker scan to queued disclosure build at 22 µs p95 on that hidden fixture. The `hidden_scan_admission` stage excludes the scan and includes the Snapshot handoff. Its separate `hidden_admission` stage measures publication after the disclosure worker completes.

## Maximum benchmark fixture

`zig build bench-buffer-search -- 4096` measures 16 Files, 131,072 changed Lines, and 2,193,960 Diff bytes. The separate hidden-match fixture has 131,074 Lines and 2,772,562 Diff bytes. Nine ReleaseFast samples measured 227 µs p95 for Query edits, 84 µs p95 for the scan-to-disclosure handoff, 41.32 ms p95 for hidden-match Buffer construction, and 10.86 ms p95 for completion admission. Escape measured 1.47 ms p95.

This fixture is larger than the 32,768-Line runs, but it did not close the ticket. At this point, completion admission still copied all projected ranges and rebuilt the File Tree on the terminal thread. Disclosure Buffer publication also reprojected accepted Buffer Search and Review Search ranges there. Stale `n` and `N` traversal and general Buffer rebuilding remained synchronous. The full suite passed with 854 tests.

The full suite passed with 854 tests. Tests cover a pending Frame, Enter before completion, rapid Query edits, cancellation, Session replacement, a changed Frame, launch failure, and allocation failure during completion admission.

## Range transfer and File Tree construction

Scan admission now takes the worker's projected ranges without copying them. If the visual rows changed during the scan, Presentation queues another scan against the current Frame instead of projecting on the terminal thread. The disclosure worker also builds the File Tree. Presentation checks the File Tree cursor, scroll, and active File before it publishes the completed Frame. Visible `n` and `N` traversal changes the active Search Occurrence without projecting the Batch again.

On the 131,072-Line fixture, `zig build bench-buffer-search -- 4096` measured 0.62 ms p95 for top-origin admission and 2.98 ms p95 for bottom-origin admission. The hidden fixture measured 0.53 ms p95 for disclosure admission. Nine ReleaseFast samples produced each measurement. The full suite passed with 854 tests.

At this point, the issue remained open. Disclosure admission still projected accepted Buffer Search and Review Search ranges on the terminal thread. Visible `n` and `N` still searched visual rows for the target. Hidden traversal, Escape restoration, and general Buffer rebuilds still used synchronous Buffer construction. The 131,072-Line benchmark measured 445 ms p95 for synchronous disclosure rebuilding.

## Worker projection and disclosure transitions

The disclosure worker now retains the accepted Buffer Search and Review Search Batches and projects their ranges before publication. The terminal loop transfers those ranges into one complete Frame. Hidden `n` and `N` traversal, Escape restoration, cursor movement that restores search-owned disclosures, and manual disclosure toggles also queue worker Buffer builds. A newer Query or Session rejects an old completion. Review Search source updates keep a Batch alive while a worker reads it.

On the 131,072-Line fixture, nine samples of `zig build bench-buffer-search -- 4096` measured 0.63 ms p95 for hidden-match admission and 0.03 ms p95 for Escape dispatch. The worker restored the hidden fixture in 0.09 ms p95, and restoration admission took 1.58 ms p95. The benchmark's synchronous disclosure build still measured 654 ms p95. The full suite passed with 860 tests.

At this point, the issue remained open. Visible `n` and `N` still searched visual rows on the terminal thread. Query edits that cleared a Query could still restore disclosures synchronously. Layout, Scope, File isolation, resize, File Enrichment, and Draft changes still rebuilt Buffers synchronously. The worker snapshot also copied all Draft bodies on the terminal thread when a disclosure build started.

## Large-Session view changes and painting

Clearing a Query now stages disclosure restoration when the Buffer must change. Scans and disclosure builds retain navigation rows for visible Search Occurrences. Visible `n` and `N` reuse those rows. Presentation sorts projected ranges before publication, and painting reads only ranges in the visible DiffPane rows. Review Search also takes the worker's completed Batch without cloning it on the terminal thread. Batches retained for workers use a thread-safe allocator.

For Sessions with more than 4,096 Buffer Search Candidates, Layout, Scope, Selected Version, File isolation, isolated File movement, and width changes now queue worker Buffer builds. The worker rebuilds the search corpus and the accepted Batch, then publishes the Buffer, File Tree, search ranges, and preferences together. A newer view request replaces a queued one. Frame or File Tree changes trigger another build against the current Session. The large-Session decision persists after isolation reduces the current corpus.

Nine samples of `zig build bench-buffer-search -- 4096` measured 0.004 ms p95 for top-origin scan admission, 1.29 ms for bottom-origin admission, 0.02 ms for Escape dispatch, and 0.01 ms for hidden-match admission on the 131,072-Line fixture. Clearing a Query measured 0.02 ms p95 for dispatch and 1.55 ms p95 for restoration admission on the separate hidden fixture. View dispatch measured 0.96 ms p95, worker construction measured 0.99 s p95, and view admission measured 3.23 ms p95. Painting measured 1.26 ms p95. The full suite passed with 863 tests.

The ticket remains open. Layout, Scope, Selected Version, and File isolation on smaller Sessions still use synchronous builds. File Enrichment, Draft mutations, and some Sidebar actions still rebuild Buffers on the terminal thread. Worker handoff still copies all Draft bodies on the terminal thread. Hidden-occurrence navigation can still scan visual rows for a disclosure marker.

File Enrichment needs a staged cache update until a worker completes the new Frame. `Storage.stageAdmission` allows only one pending cache update, so a second completion cannot replace the first without a new handoff rule. Draft saves must also keep persistence and Frame publication atomic. Both paths need that ownership work before their Buffer builds can move to workers.

## File Enrichment Frame staging

File Enrichment results now stay private while a disclosure worker builds the Buffer, File Tree, search corpus, and projected ranges. The worker previews the result and cache evictions against a copy of the cache state. Presentation checks the Session Epoch, Frame revision, Query generation, and cache revision before it admits the result and publishes the complete Frame. A second completion can wait in its own worker build. If the first admission changes the cache, Presentation rebuilds the second Frame against the new state. Failed builds release their results and leave the published Frame and cache content unchanged.

Review Search source opening still rebuilds its destination Buffer after File Enrichment publication. Draft saves, smaller-Session view changes, and other general Buffer rebuilds still run on the terminal thread. `zig build test --summary all` passed with 867 tests.

## Buffer Search work ownership

Presentation now checks the completion family before it removes an issued command id. An unrelated completion cannot release the Buffer Search worker lane. Session replacement releases queued scans and disclosure builds, including staged File Enrichment Frames. Issued workers retain their inputs until completion, then Presentation rejects their old Session Epoch.

Query edits and disclosure transitions preserve staged File Enrichment for the current Session. Failed Query clears and Escape restoration keep the earlier queued work. A failed Query edit does not advance the Query generation. Failed Query-clear admission releases the worker Frame and clears the pending flag. A retry preserves the disclosure-restoration flags.

The terminal adapter and runtime tests use the same scan-launch failure path. That path releases the worker Query, corpus reference, and source-coordinate projection while it preserves the completion correlation and scan mode.

Tests cover wrong-family and unknown command ids, refresh, Review switching, shutdown, closed completion sinks, Query-clear failures, and File Enrichment during Query edits. Allocation-failure tests check every scan-arena and range-projection allocation. `zig build`, formatting checks, and `zig build test --summary all` passed. The full suite contains 877 tests.

This completes the lifecycle bullet. Draft saves, smaller-Session view changes, and some general Buffer builds remain synchronous. The ticket remains open for those input stalls.

## Bounded worker handoff

`DisclosureBuild.create` now retains one cached input snapshot and one disclosure-key snapshot. The input snapshot owns the Draft bodies, AnchorSnapshots, ScopeProjection, Directory paths, File Enrichment tables, and File leases. Frame preparation updates the snapshot before publication. Disclosure-only builds reuse it. File Enrichment workers prepare replacement snapshots before admission. Each replacement retains only the File content that its projection uses.

Buffer Search retains saved disclosure keys instead of copying complete key arrays during handoff. A disclosure command sends a retained baseline plus at most three additions or one removal. The worker constructs the complete target keys. Query text and the File Tree cursor path remain per-command copies.

DraftState changes update an unshared snapshot or replace a retained snapshot. Admission checks the input snapshot identity as well as the existing command, Session Epoch, Query generation, Frame revision, and geometry. A worker can finish against its retained Draft body and AnchorSnapshot after an edit. Presentation rejects that old Frame and retries against the current inputs.

File Enrichment workers copy cache evidence from atomic per-File records. The existing cache revision check rejects a copy that overlaps a cache change. The terminal thread no longer copies the complete cache-entry table when it queues a worker.

`zig build bench-buffer-search -- 256` uses nine ReleaseFast samples. Before the change, the one-File fixture had 1,024 Drafts and 4,194,304 body bytes. Handoff measured 276,125 ns median and 313,959 ns p95. After the change, the same fixture measured 1,333 ns median and 3,417 ns p95.

The added fixture has 1,024 enriched Files, 1,024 Drafts, 4,194,304 body bytes, and 4,194,304 AnchorSnapshot bytes. It also has 1,024 ScopeProjection entries, 1,024 collapsed Directories, and 1,024 expanded ReviewCards.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| One-File worker handoff | 1,333 | 3,417 |
| One-File snapshot-copy control | 272,042 | 326,750 |
| Many-input worker handoff | 1,917 | 6,583 |
| Many-input snapshot-copy control | 572,542 | 690,417 |

The snapshot-copy controls measure complete input copies and File lease acquisition outside production handoff. The benchmark builds each fixture before timing. Snapshot refresh during initial Session publication and synchronous Draft or general Frame builds remains part of the later work in this ticket. Disclosure lookup and navigation restoration also remain separate work.

Tests cover DraftState changes, Draft edits during issued worker work, and allocation failures in disclosure and File Enrichment workers. The existing lifecycle tests cover cancellation, stale work, Session replacement, launch failure, and a closed completion sink. `zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 880 tests. The ticket remains `ready-for-agent` for the next remaining item.

## New Draft Frame staging

New Draft saves now use the existing Frame worker for every Session size. Presentation reserves a TempId and copies only the new Draft into the worker command. The worker retains the current input snapshot. It adds the candidate Draft and its current ScopeProjection. It then builds the Buffer, visual rows, File Tree, search corpus, and search ranges. The worker also prepares the replacement input snapshot.

The old PendingReview, ScopeProjection, Frame, and Composer remain published while the worker runs. Admission checks the command id, Session Epoch, reserved TempId, Query generation, and input snapshot. It also checks the Frame revision, geometry, and File Tree state. A stale Frame retries with the same TempId. Admission completes all allocations before persistence. A successful write publishes the Draft and complete Frame, then closes the Composer. A failure keeps the old projection and Composer body.

Repeated save input keeps one pending save. Composer edits, cancellation, and External Edit cancel the pending save. Issued workers retain their inputs until completion. Refresh, Review switching, and shutdown reject work from a replaced or closed Session.

`zig build bench-buffer-search -- 256` measured nine ReleaseFast samples. Each Draft fixture starts with 1,024 Drafts and 4,194,304 body bytes. Each sample saves a nine-byte Review-level Draft. The measured Frames contain 1,025 through 1,033 Drafts. The many-input fixture also has 1,024 enriched Files and 4,194,304 AnchorSnapshot bytes. It has 1,024 collapsed Directories and 1,024 expanded ReviewCards. The synchronous control builds the same saved Draft graph through `prepareBuffer` without publication.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| One-File Draft save dispatch | 7,334 | 40,125 |
| One-File Draft worker build | 124,270,125 | 133,277,167 |
| One-File Draft admission | 10,331,167 | 11,465,375 |
| One-File synchronous Buffer control | 101,277,417 | 130,798,458 |
| Many-input Draft save dispatch | 12,292 | 43,500 |
| Many-input Draft worker build | 744,866,666 | 770,106,333 |
| Many-input Draft admission | 9,985,250 | 12,296,584 |
| Many-input synchronous Buffer control | 716,660,500 | 745,116,583 |

The save Action no longer builds a Buffer on the terminal thread. Admission still includes persistence, navigation restoration, and release of the previous Frame. These measurements do not close the remaining admission-latency work.

Tests cover delayed persistence and publication, repeated saves, stale Frame retries, and accepted Buffer Search. They also cover Composer changes, refresh, Review switching, and shutdown. Worker allocation-failure tests include the new Draft path. Admission tests cover allocation and persistence failures after reservation. Runtime tests cover launch failure and a closed completion sink. Existing tests cover local AnchorSnapshots, Reply parentage, Suggestion fencing, and restoration from persistence.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 886 tests. The ticket remains `ready-for-agent`. The next remaining item is Draft mutation Buffer staging.

## Draft mutation Frame staging

Draft body edits, re-anchor, Draft subtree deletion, and confirmation of an unpublished outcome now use the Frame worker for every Session size. Presentation copies only the changed body or replacement Anchor and AnchorSnapshot into the command. Deletion and outcome repair send only the root TempId. The worker retains the input snapshot and constructs the candidate PendingReview and ScopeProjection privately. It also builds the Buffer, visual rows, File Tree, search corpus, search ranges, and replacement input snapshot.

The published PendingReview, ScopeProjection, Frame, and interaction remain unchanged while the worker runs. Admission checks the command id, Session Epoch, mutation request, Query generation, input snapshot, Frame revision, geometry, and File Tree state. It rechecks mutation eligibility before the store write. A changed Frame or Query retries the same mutation request against the current inputs. The worker computes the complete deletion subtree. The store rechecks that subtree inside its write.

Presentation completes all allocations before persistence. A successful write publishes the changed graph and complete Frame together. Body edits close the Composer after publication. Re-anchor and deletion clear their interactions after publication. A failed build or write keeps the earlier Frame and authored data. Body changes, Composer cancellation, External Edit, re-anchor cancellation, and deletion cancellation reject pending mutation work. Issued workers retain their inputs until completion. Session replacement and shutdown reject their completions.

`zig build bench-buffer-search -- 256` measured nine ReleaseFast samples without concurrent build or test work. Each mutation fixture retains the 1,024 original Drafts and the nine Drafts from the save benchmark. Those 1,033 Drafts contain 4,194,385 body bytes. Each sample adds an inline root and a two-deep Reply chain before timing. The three added Drafts contain 12,288 body bytes. The body edit adds eight bytes to the root. Body edit, re-anchor, and outcome repair build Frames with 1,036 Drafts. Subtree deletion returns the Frame to 1,033 Drafts.

The one-File fixture has no collapsed Directories or expanded ReviewCards. The many-input fixture has 1,024 enriched Files and 4,194,304 AnchorSnapshot bytes. It also has 1,024 collapsed Directories and 1,024 expanded ReviewCards. Fixture preparation, interaction setup, and unknown-outcome setup occur before timing. The synchronous control builds the same graph through `prepareBuffer` after each admitted mutation, without publication. Values are nanoseconds.

### One-File fixture

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Body edit dispatch | 10,959 | 12,792 |
| Body edit worker build | 129,771,125 | 130,898,417 |
| Body edit admission | 187,500 | 317,833 |
| Body edit synchronous Buffer control | 104,664,708 | 107,104,916 |
| Re-anchor dispatch | 12,333 | 14,041 |
| Re-anchor worker build | 130,585,333 | 136,613,375 |
| Re-anchor admission | 344,875 | 392,333 |
| Re-anchor synchronous Buffer control | 105,191,083 | 110,541,917 |
| Outcome repair dispatch | 297,042 | 334,166 |
| Outcome repair worker build | 130,115,041 | 131,095,250 |
| Outcome repair admission | 305,792 | 345,792 |
| Outcome repair synchronous Buffer control | 102,595,416 | 106,147,875 |
| Subtree deletion dispatch | 251,875 | 272,125 |
| Subtree deletion worker build | 129,653,833 | 131,678,500 |
| Subtree deletion admission | 9,640,167 | 10,691,875 |
| Subtree deletion synchronous Buffer control | 104,450,084 | 105,263,916 |

### Many-input fixture

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Body edit dispatch | 20,042 | 23,250 |
| Body edit worker build | 764,328,875 | 799,547,750 |
| Body edit admission | 565,083 | 1,137,500 |
| Body edit synchronous Buffer control | 729,604,625 | 786,951,542 |
| Re-anchor dispatch | 14,833 | 18,458 |
| Re-anchor worker build | 764,108,292 | 879,291,541 |
| Re-anchor admission | 848,292 | 1,198,541 |
| Re-anchor synchronous Buffer control | 731,125,708 | 782,729,084 |
| Outcome repair dispatch | 1,168,666 | 1,247,542 |
| Outcome repair worker build | 760,504,125 | 785,241,459 |
| Outcome repair admission | 874,167 | 1,228,792 |
| Outcome repair synchronous Buffer control | 730,746,709 | 754,262,541 |
| Subtree deletion dispatch | 251,750 | 267,458 |
| Subtree deletion worker build | 754,441,292 | 955,372,417 |
| Subtree deletion admission | 10,891,667 | 18,568,458 |
| Subtree deletion synchronous Buffer control | 728,679,208 | 871,954,750 |

The mutation Actions no longer build a Buffer on the terminal thread. Dispatch still includes target and eligibility lookup. Admission still includes persistence, navigation restoration, and release of the earlier Frame. Subtree deletion reaches 18.57 ms p95 admission on the many-input fixture. These measurements leave the later admission-latency work open.

Tests cover delayed persistence and publication for all four mutations, repeated input, stale Frame and Query retries, and accepted and open Buffer Search. They also cover queued and issued cancellation, Composer body changes, changed DraftState, refresh, Review switching, and shutdown. Worker allocation-failure tests cover all four candidate graphs and replacement input snapshots. Admission allocation-failure tests cover changed bodies and AnchorSnapshots. Write-failure tests preserve the graph, Frame, and interaction before a successful retry. Runtime tests cover launch failure and a closed completion sink for every mutation. Existing tests retain Reply parentage, Suggestion fencing, LocalReview AnchorSnapshots, deletion navigation, monotonic TempIds, and persistence restoration.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 897 tests. The ticket remains `ready-for-agent`. The next remaining item is view-change Buffer staging.

## View-change Frame staging

Layout, Scope, Selected Version, File isolation, isolated File movement, and width changes now use workers for every Session size. The implementation removes `stageLargeBuffer` and its 4,096-Candidate threshold. Resolved Thread visibility keeps the existing worker disclosure path. Height-only changes still reuse the Buffer and visual rows when no view build is pending.

View requests use a separate generation from Buffer Search Queries. A Query edit no longer drops a queued width build. The newest queued view request keeps the requested preferences, File isolation, geometry, and navigation policy. A stale completion cannot replace that request. Admission retries changed Query input, accepted search, File Tree state, input snapshots, or visual rows against the current Session.

The view worker rebuilds the search corpus and both accepted and input Batches. It also projects their ranges and navigation rows. Presentation publishes those results with the Buffer, File Tree, preferences, isolation, and geometry. Width admission restores the saved Buffer Search navigation before it releases the earlier worker Frame. Escape therefore restores the origin in the current geometry. Enter still waits for the newest pending Query. Isolation exit retains the requested File header across queued movement and resize requests.

The benchmark now measures width dispatch during pending Buffer Search input. It measures worker construction and admission separately. The synchronous control calls `prepareBuffer` for the same geometry and Query without publication. Both paths check the visual-row, Search Occurrence, and projected-range counts. Each fixture contains 16 Files and no Drafts or ReviewCards. Each run uses nine ReleaseFast samples, without concurrent build or test work. Width samples alternate between 80 and 100 terminal columns with 30 rows. Values are nanoseconds.

### Small Session

`zig build bench-buffer-search -- 32` uses 1,024 changed Lines and 16,232 Diff bytes. This fixture has fewer than 4,096 Candidates.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Layout dispatch | 4,666 | 25,167 |
| Layout worker build | 5,738,708 | 6,286,541 |
| Layout admission | 49,083 | 72,542 |
| Width dispatch during pending input | 3,167 | 3,875 |
| Width worker build | 6,294,750 | 7,964,042 |
| Width admission | 82,167 | 94,541 |
| Synchronous width Buffer control | 22,144,084 | 23,651,417 |

### Larger Session

`zig build bench-buffer-search -- 256` uses 8,192 changed Lines and 128,776 Diff bytes.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Layout dispatch | 23,875 | 28,792 |
| Layout worker build | 40,919,125 | 59,882,334 |
| Layout admission | 239,583 | 325,000 |
| Width dispatch during pending input | 3,375 | 4,166 |
| Width worker build | 51,569,000 | 69,165,875 |
| Width admission | 336,583 | 441,750 |
| Synchronous width Buffer control | 188,997,583 | 233,112,959 |

These measurements cover view dispatch and width publication. Admission still restores navigation and releases the earlier Frame on the terminal thread. The later admission-latency work remains open.

Tests cover delayed publication and failed builds for each view change. They also cover queued request composition, reversed Selected Version requests, isolated File focus, isolation exit, and stale completions. Small and large Sessions exercise resize during rapid Query edits and Enter. Repeated width builds preserve Escape navigation across worker Frames. Worker allocation-failure tests include view builds. Runtime tests cover launch failure and a closed completion sink. Session tests cover refresh, Review switching, shutdown, and navigation retries.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 904 tests. The ticket remains `ready-for-agent`. The next remaining item is Sidebar-triggered Buffer rebuilding.

## Sidebar File Tree updates

Directory expansion, Directory collapse, and active-File reveal now update only the File Tree. Presentation builds the candidate File Tree in a separate `ArenaRing`. Publication replaces the File Tree and its Directory snapshot together. It keeps the Buffer, visual rows, search corpus, Batches, projected ranges, and DiffPane navigation. An unchanged active-File reveal updates active flags and Sidebar scroll without an allocation.

Directory snapshots retain the existing Drafts, ScopeProjection, File Enrichment tables, and File leases. Each snapshot retains the content owner directly. Repeated Directory changes do not retain a chain of earlier Directory snapshots. Worker admission rejects an earlier snapshot and retries against the current File Tree. Allocation failure preserves the previous File Tree and collapsed Directories.

`zig build bench-buffer-search -- 32` measured nine ReleaseFast samples without concurrent build or test work. The Sidebar fixture has 1,024 enriched Files and 2,048 changed Lines. It also has 1,024 Drafts, 4,194,304 body bytes, and 4,194,304 AnchorSnapshot bytes. Each File lives under `src/dN`. Samples start with 1,024 collapsed Directories and 1,024 expanded ReviewCards. Collapse and expansion toggle the shared `src` Directory. Active-File reveal opens `src/d0`. Reveal timings exclude File-header lookup and DiffPane movement. The synchronous control builds the same expanded File Tree and Buffer through `prepareBuffer` without publication. Values are nanoseconds.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Directory collapse dispatch | 1,889,125 | 1,914,041 |
| Directory expansion dispatch | 2,309,875 | 2,418,584 |
| Hidden active-File reveal | 1,423,667 | 1,438,500 |
| Visible active-File reveal | 4,375 | 5,208 |
| Synchronous Buffer control | 723,598,084 | 730,641,875 |

File Tree construction still depends on the File and Directory counts. The Sidebar paths no longer rebuild Draft bodies or DiffPane content. The benchmark checks that Buffer rows, visual rows, and their revision remain unchanged.

Tests cover unchanged DiffPane navigation and accepted search ranges during Directory changes. They also cover allocation-free visible reveal, nested Directory reveal, stale worker retries, retained Draft content, and allocation failures. The existing mouse tests cover the same Sidebar Actions.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 909 tests. The ticket remains `ready-for-agent`. The next remaining item is Review Search destination Buffer staging.

## Review Search destination Frame staging

Review Search now queues the existing Frame worker for source and ReviewBody destinations on every Session size. The worker builds the Buffer, visual rows, File Tree, search corpus, and search ranges. The worker also finds the exact destination row. If a Fold hides the source occurrence, the worker adds its disclosure key. The worker then builds the revealed Buffer.

Presentation keeps the previous Frame, preferences, isolation, navigation, and Overlay while the worker runs. Repeated Enter input keeps one destination request. Admission checks the command id, Session Epoch, Review Search Query generation, and destination generation. Admission also checks the selected occurrence, Buffer Search generation, retained Batches, and input snapshot. Admission checks the cache revision, geometry, and File Tree state. A changed Frame retries the same selected occurrence against the current inputs. Query edits, selection changes, Escape, Session replacement, and shutdown reject the earlier destination.

Presentation completes disclosure allocations before publication. A failed worker or admission preserves the previous Frame and Overlay for another Enter. A successful admission publishes the complete destination Frame and preferences together. Presentation then moves the cursor and closes the Overlay. Source destinations retain the original disclosure baseline for restoration when Buffer Search starts. File Enrichment publication queues the same destination worker when an occurrence waits for content.

`zig build bench-buffer-search -- 256` measured nine ReleaseFast samples without concurrent build or test work. The source fixture has one File, 8,194 Diff Lines, and 162,814 Diff bytes. Both complete File versions are available before the measurements. The source occurrence starts inside a Fold. Each ReviewBody fixture contains 1,024 Drafts and 4,194,304 body bytes. The many-input fixture also has 1,024 enriched Files and 4,194,304 AnchorSnapshot bytes. The many-input fixture has 1,024 collapsed Directories and 1,024 expanded ReviewCards.

The benchmark measures destination dispatch, worker construction, and admission separately. The synchronous control calls `prepareBuffer` after admission with the same destination preferences and disclosures. The control checks the visual-row and projected-range counts. Fixture preparation, Query scanning, and source disclosure restoration occur before the timed stages. Values are nanoseconds.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Source destination dispatch | 10,500 | 12,041 |
| Source destination worker | 2,463,792 | 2,658,459 |
| Source destination admission | 40,083 | 57,917 |
| Source synchronous Buffer control | 49,089,084 | 52,243,000 |
| One-File ReviewBody destination dispatch | 26,625 | 97,167 |
| One-File ReviewBody destination worker | 135,032,875 | 138,491,416 |
| One-File ReviewBody destination admission | 9,318,084 | 10,319,166 |
| One-File synchronous Buffer control | 112,262,417 | 129,078,125 |
| Many-input ReviewBody destination dispatch | 117,375 | 196,750 |
| Many-input ReviewBody destination worker | 889,107,292 | 934,340,166 |
| Many-input ReviewBody destination admission | 13,114,041 | 15,291,417 |
| Many-input synchronous Buffer control | 868,403,875 | 910,313,208 |

Destination dispatch no longer constructs a Buffer. Admission still restores navigation and releases the previous Frame on the terminal thread. `releaseReviewSearchHolds` and queued source-lease release can still rebuild after cache eviction. Those paths remain in the cache-focus and lease-release item. The many-input destination measures 15.29 ms p95 admission. The later admission-latency work remains open.

Tests cover delayed publication, repeated Enter, changed geometry, changed File Tree state, Query edits, selection changes, and Escape. Tests also cover refresh, Review switching, shutdown, and destination opening after File Enrichment publication. Worker allocation-failure tests cover ReviewBody construction and both source Buffer builds. Admission allocation-failure tests preserve disclosures, isolation, cache focus, and the Overlay before a successful retry. Runtime tests cover launch failure and a closed completion sink. Existing tests retain exact wrapped ranges, Selected Version, Scope, isolation, outdated content, and temporary source Fold restoration.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 915 tests. The Standards and Spec review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is disclosure restoration when Buffer Search starts after Review Search.

## Buffer Search opening restoration

`openBufferSearch` now queues the disclosure worker when Review Search owns temporary disclosures. It retains the saved disclosure keys and cached corpus without copying the full baseline. Review Search and its worker snapshots now share reference-counted `DisclosureKeys`.

Buffer Search captures input immediately. Query edits retain only the newest Query while restoration runs. Enter waits for restoration and the newest scan. Clearing the Query keeps the restoration request. Admission publishes the complete Buffer, visual rows, File Tree, and projected ranges together. It also restores the saved navigation and origin against the new rows before releasing the earlier Frame.

Each opening has its own request id. Escape and immediate reopening reject an earlier opening, even when both retain the same baseline. Frame, geometry, input snapshot, or File Tree changes cause a retry. Successful admission releases Review Search's disclosure baseline. A failed build or admission preserves the previous Frame and baseline for retry. A width build can publish input ranges while restoration waits. Restoration admission discards those old input ranges before it queues the newest scan.

`zig build bench-buffer-search -- 256` measured nine ReleaseFast samples without concurrent build or test work. The source fixture has one File, 8,194 Diff Lines, and 162,814 Diff bytes. Both complete File versions are available. The selected Review Search occurrence starts inside a Fold. Fixture preparation and destination opening occur before the restoration measurements.

The benchmark measures opening dispatch, a Query edit during restoration, worker construction, and admission separately. It clears that Query before admission. The synchronous control calls `prepareBuffer` with the same saved baseline before opening. Both paths check the visual-row and Review Search range counts. Values are nanoseconds.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Opening dispatch after Review Search | 17,959 | 63,583 |
| Query edit during restoration | 2,625 | 3,292 |
| Restoration worker | 13,917 | 16,334 |
| Restoration admission | 222,166 | 246,250 |
| Synchronous restoration Buffer control | 414,042 | 458,875 |

Opening no longer constructs a Buffer on the terminal thread. Admission still restores navigation and releases the earlier Frame there. This source fixture does not measure restoration with many ReviewCards or cached Files. The later benchmark and admission-latency items remain open.

Tests cover queued and issued restoration, rapid edits, Query clearing, Enter, Count, and accepted search. They also cover Escape, immediate reopening, changed geometry, changed File Tree state, and width publication before restoration. Allocation failures preserve the Frame, baseline, Query, and generation. Worker allocation-failure tests include restoration. Runtime tests cover launch failure and a closed completion sink. Session tests cover refresh, Review switching, and shutdown.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 922 tests. The Standards and Spec review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is File Enrichment cache-focus and lease-release Frame staging.

## File Enrichment cache-focus and lease-release Frame staging

File focus changes that need eviction now queue the existing Frame worker. Source-scan lease release also queues that worker. Review Search closure, Query clearing, and destination admission release their holds before they queue one cache Frame. Lease bookkeeping ends immediately, but cache content stays available until the complete Frame can publish. Focus changes without eviction keep their direct metadata update.

The worker copies the private File Enrichment tables and reads the atomic cache records. It chooses the eviction victims and builds the Buffer, visual rows, File Tree, search corpus, and search ranges. It also prepares the replacement input snapshot. Admission checks the command id, Session Epoch, cache request id, cache revision, and Query generation. It also checks the retained Batches, input snapshot, visual-row revision, geometry, active File, and File Tree state. A changed input causes a retry. A newer focus request replaces the queued request and rejects an earlier issued completion.

Admission applies the worker's victim list without another LRU search. It publishes cache content, cache focus, and the complete Frame together. The cache Frame borrows the replacement input snapshot. Admission releases its earlier snapshot so the published worker Frame does not retain evicted File content. Failure preserves the previous Frame and cache content. Buffer Search input keeps its Query, projected ranges, saved navigation, and origin across publication.

`zig build bench-buffer-search -- 32` measured nine ReleaseFast samples without concurrent build or test work. The cache fixture has 1,024 Files and 2,048 changed Lines. Each sample starts with all 1,024 Files enriched. The fixture has 1,033 Drafts and 4,194,385 body bytes. It also has 4,194,304 AnchorSnapshot bytes, 1,023 collapsed Directories, and 1,024 expanded ReviewCards. Cache policy disables inactive caching. The focus case evicts the previous focused File. The source-lease case evicts one inactive File. The hold-release case evicts 1,023 inactive Files.

Fixture restoration, File Enrichment, hold acquisition, and navigation setup occur before timing. The synchronous control calls `prepareBuffer` after admission with the same cache projection. Both paths check the Buffer and visual-row counts. Values are nanoseconds.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Cache focus dispatch | 12,958 | 18,958 |
| Cache focus worker | 768,893,667 | 919,698,333 |
| Cache focus admission | 1,175,875 | 2,001,291 |
| Cache focus synchronous Buffer control | 727,298,417 | 789,723,375 |
| Source lease release dispatch | 12,959 | 42,292 |
| Source lease release worker | 788,290,959 | 814,584,250 |
| Source lease release admission | 1,313,750 | 1,892,375 |
| Source lease release synchronous Buffer control | 753,277,958 | 779,614,875 |
| Review Search hold release dispatch | 56,583 | 1,168,917 |
| Review Search hold release worker | 762,549,459 | 821,989,125 |
| Review Search hold release admission | 9,102,666 | 11,134,417 |
| Review Search hold release synchronous Buffer control | 732,209,208 | 778,710,542 |

These paths no longer construct a Buffer on the terminal thread. Hold release still visits the held-File table. Admission still restores navigation and releases the earlier Frame there. The later admission-latency and benchmark items remain open.

Tests cover delayed cache and Frame publication, repeated focus input, queued and issued focus replacement, and retry after failure. Tests also cover changed Query input, geometry, File Tree state, and lease protection. Source lease release, Review Search closure, and Query clearing preserve accepted Buffer Search. A retained read lease verifies that the published cache Frame releases the evicted content. Worker allocation-failure tests include cache Frames. Runtime tests cover launch failure and a closed completion sink. Session tests cover refresh, Review switching, and shutdown. The source-opening test waits for staged eviction before it checks refetch behavior.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 929 tests. The Standards and Spec review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is hidden Search Occurrence navigation and disclosure lookup indexing.

## Indexed Search Occurrence navigation and disclosure lookup

Each complete Frame now owns immutable search indexes in its retained `SearchProjection`. Frame construction indexes visible source coordinates and ReviewBody owners. It also indexes Fold membership, disclosure rows, and inherited Comment and Draft disclosure chains. Disclosure workers build these indexes before Frame publication. Scan workers retain the same indexes with their copied source coordinates.

`requiredSearchDisclosure` uses indexed source coordinates or a typed ReviewBody owner. `searchOccurrenceNavigationRow` first checks the indexed visible rows. Hidden occurrences use at most three indexed disclosure rows. Visible lookup uses binary search within one source Line or ReviewBody owner. The terminal thread no longer searches the complete visual rows, Buffer rows, Hunks, Threads, or Draft parent chains for these lookups.

`DisclosureKeys` now indexes key membership and records each worker's bounded changes against an immutable baseline identity. Search transitions compare those identities and changes instead of complete key arrays. An unknown baseline identity queues a worker. Hidden `n`, `N`, Count, Query clearing, and scan admission use the indexed lookups. Traversal within the same revealed Fold keeps the current Frame. Query clearing retains the accepted occurrence's required disclosures.

`zig build bench-buffer-search -- 4096` measured nine ReleaseFast samples without concurrent build or test work. The main fixture has 16 Files, 131,072 changed Lines, and 2,193,960 Diff bytes. The hidden fixture has one File, 131,074 Lines, and 2,772,562 Diff bytes. Its accepted Query has one hidden occurrence. Each traversal sample collapses that occurrence before timing. Worker construction and fixture restoration occur outside the traversal measurements. The Count sample uses 999.

The ReviewBody fixtures each have 1,024 Drafts and 4,194,304 body bytes. Lookup targets the final authored byte of the last Draft. The one-File fixture keeps its ReviewCards collapsed. The many-input fixture has 1,024 enriched Files, 1,024 collapsed Directories, and 1,024 expanded ReviewCards. It also has 4,194,304 AnchorSnapshot bytes. Linear controls search the same published rows and check the destination row. The hidden source control also uses the earlier Hunk and Fold lookup. Values are nanoseconds.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Hidden source lookup | 83 | 1,250 |
| Hidden source linear control | 44,292 | 63,625 |
| Hidden `n` dispatch | 10,833 | 17,625 |
| Hidden `N` dispatch | 12,083 | 15,375 |
| Hidden Count dispatch | 11,583 | 15,125 |
| Scan-to-disclosure handoff | 6,625 | 8,667 |
| Query clear dispatch | 11,209 | 14,250 |
| One-File ReviewBody lookup | 125 | 13,041 |
| One-File ReviewBody linear control | 33,334 | 136,417 |
| Many-input ReviewBody lookup | 166 | 2,167 |
| Many-input ReviewBody linear control | 251,375 | 269,583 |

Index construction remains part of Frame construction. Initial Session publication and synchronous benchmark controls therefore also construct the indexes. Completion admission still walks Batches for active-occurrence retention and origin selection. The next remaining item covers those Batch walks.

Tests cover hidden forward and backward traversal, Count, same-Fold traversal, Query clearing, and disclosure restoration. They also cover resolved Replies, nested Draft chains, outdated placement, and opposite-version placement. Wrapped source and ReviewBody lookups match the linear reference in both Layouts at two terminal widths. A retained-index test removes the current row, File, and Thread tables before lookup. Allocation-failure tests check every search-index allocation. Existing transition tests cover stale Frames, cancellation, Session replacement, and worker failures.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 934 tests. The Standards and Spec review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is bounded active-occurrence retention and origin selection during completion admission.

## Bounded Batch selection

Worker projection now builds sorted indexes for edited and exact Search Occurrence identities. Edited identity uses the location and first authored range start. Exact identity also uses the Session Epoch and complete ranges. Edited identity keeps the first Batch index when several occurrences share that identity. Query refinement therefore retains the same occurrence when its range end changes. Worker Frame admission also uses the exact index to retain an open input occurrence.

The worker computes navigation prefix maxima and suffix minima in Batch order. Each destination uses its visible row or indexed disclosure row. Binary lookup selects the first occurrence at or after the origin. Inactive `n` selects the first occurrence strictly after the cursor. Inactive `N` selects the last occurrence strictly before the cursor. These lookups preserve occurrence order when visual rows are not monotonic. Count and wrap status keep their earlier rules.

The selection indexes share one allocation with the projected navigation rows. Scan and Frame completions transfer that allocation with their Batch and ranges. Existing command, Session Epoch, Query generation, and Frame checks reject stale work before selection. Synchronous Frame controls also publish navigation indexes so they cannot remove the accepted search's lookup data.

Both benchmark runs use nine ReleaseFast samples without concurrent build or test work. `zig build bench-buffer-search -- 256` has 16 Files, 8,192 changed Lines, and 128,776 Diff bytes. `zig build bench-buffer-search -- 4096` has 16 Files, 131,072 changed Lines, and 2,193,960 Diff bytes. Each Query produces one occurrence per changed Line. The selection measurements use SideBySide Frames with 4,128 and 65,568 visual rows, respectively. Neither fixture contains Drafts or ReviewCards.

The retention sample extends `needl` to `needle` from the bottom origin. Worker scanning completes before admission timing. Inactive traversal starts at the bottom for `n` and at the top for `N`. The Count sample uses 999. Fixture setup and cursor movement occur before timing. Linear controls select the same occurrence and check the indexed result. Values are nanoseconds.

| Stage | 8,192 occurrences median | 8,192 occurrences p95 | 131,072 occurrences median | 131,072 occurrences p95 |
| --- | ---: | ---: | ---: | ---: |
| Retention lookup | 292 | 3,000 | 5,625 | 11,708 |
| Retention linear control | 16,167 | 56,458 | 1,281,166 | 2,385,500 |
| Bottom-origin lookup | 42 | 167 | 500 | 3,875 |
| Bottom-origin linear control | 15,208 | 15,834 | 477,458 | 629,417 |
| Query-refinement admission | 88,292 | 159,292 | 2,156,209 | 2,536,333 |
| Inactive `n` dispatch | 11,125 | 11,833 | 149,583 | 163,917 |
| Inactive `N` dispatch | 11,084 | 15,667 | 160,667 | 170,958 |
| Inactive Count dispatch | 10,917 | 12,458 | 157,250 | 173,666 |
| Inactive forward linear control | 15,542 | 27,875 | 784,541 | 1,010,834 |
| Inactive backward linear control | 15,291 | 15,916 | 257,375 | 281,458 |

On the 8,192-Line fixture, bottom-origin scan admission measured 14,291 ns median and 20,625 ns p95 before this change. After this change, the same stage measured 458 ns median and 1,000 ns p95. On the 131,072-Line fixture, it measured 2,541 ns median and 2,834 ns p95. This stage has no previous input Batch to release. Query-refinement admission also releases the previous Batch and ranges, so its total latency remains larger than the indexed retention lookup.

The published navigation allocation uses 64 bytes per occurrence on this target. The two selection fixtures use 524,288 and 8,388,608 bytes. Worker projection includes index construction. The 131,072-Line fixture measured worker projection at 20,874,208 ns median and 26,146,625 ns p95. Terminal selection performs logarithmic lookup without a complete Batch walk or index allocation.

Tests compare indexed selection with linear selection in both Layouts at 45 and 100 columns. They cover wrapped source and ReviewBody ranges, hidden Folds and resolved Threads, typed Comment and Draft owners, and unavailable destinations. They also cover unordered Batches, duplicate identities, changed range ends, disappearing occurrences, empty Batches, Count, wrap status, and synchronous Frame publication. Existing tests cover rapid Query edits, pending Enter, stale Frames, cancellation, Session replacement, and worker failures. Allocation-failure tests exercise the new projection allocations.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 936 tests. The Standards and Spec self-review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is bounded navigation restoration during worker Frame admission.

## Bounded Frame navigation restoration

Each Frame now builds a `NavigationIndex` inside its retained `SearchProjection`. Exact ownership lookup keeps the first visual row for each owner. Source-span lookup indexes both SideBySide halves and typed Comment and Draft owners. Sorted spans and prefix end maxima support binary lookup for containing rows and following rows. Section keys own their path bytes.

Worker Frame admission uses the index for the cursor and Selection. Width, cache, and disclosure restoration also use the index for saved Buffer Search navigation and origin. Admission reads the latest cursor, Selection, and Count from the published Frame. It preserves the viewport offset and the previous Selection rules. The linear restoration function remains a benchmark control and test reference. Production restoration does not call that control.

Selected Version capture now records only the source Hunk Line identity and navigation coordinates. The worker finds Hunk neighbors and chooses the destination visual row. Admission applies that destination without a row walk. File Enrichment workers carry the pending Selected Version target. Admission checks that target against the current pending restoration before it applies the destination.

Draft deletion workers retain the previous Frame's copied row identities. The worker chooses the surviving destination after it computes the complete deletion subtree. Admission uses indexed owner lookup for the surviving row and re-anchored Draft header. Next and previous File-header navigation use the existing sorted File row table. Buffer-row to visual-row lookup also uses binary search.

`zig build bench-buffer-search -- 4096` measured nine ReleaseFast samples without concurrent build or test work. The source fixture contains 16 Files, 131,072 changed Lines, and 2,193,960 Diff bytes. Its SideBySide Frame contains 65,568 visual rows at 80 terminal columns. Both ReviewBody fixtures contain 1,024 Drafts and 4,194,304 body bytes. The collapsed one-File fixture contains 8,197 visual rows. The many-input fixture contains 100,352 visual rows. It also contains 1,024 enriched Files, 1,024 collapsed Directories, 1,024 expanded ReviewCards, and 4,194,304 AnchorSnapshot bytes.

Restoration samples place the cursor on the last visual row and the Selection mark on the preceding row. Each linear control restores the same navigation and checks the complete result. File-header samples check the last File's visual header, the next header after row zero, and the previous header before Buffer end. Fixture setup and index construction occur outside these lookup measurements. Values are nanoseconds.

| Stage | Median ns | p95 ns |
| --- | ---: | ---: |
| Source navigation restoration | 250 | 19,208 |
| Source navigation linear control | 329,459 | 1,275,167 |
| Source File-header lookup | 125 | 208 |
| Source File-header linear control | 113,000 | 175,292 |
| One-File ReviewBody navigation restoration | 83 | 4,792 |
| One-File ReviewBody navigation linear control | 44,000 | 58,334 |
| One-File File-header lookup | 42 | 83 |
| One-File File-header linear control | 11,333 | 11,917 |
| Many-input ReviewBody navigation restoration | 375 | 1,209 |
| Many-input ReviewBody navigation linear control | 345,041 | 383,083 |
| Many-input File-header lookup | 333 | 958 |
| Many-input File-header linear control | 360,083 | 452,875 |
| Selected Version capture | 42 | 542 |
| Selected Version worker destination | 231,833 | 268,292 |
| Selected Version navigation admission | 0 | 42 |

The Selected Version sample changes from new to old at the bottom source row. Worker destination work includes the earlier Hunk-neighbor and visual-row walks. The zero admission median falls below the clock's measurement resolution. It does not mean that admission has no cost.

These measurements isolate navigation work. Complete admission still includes persistence and release of the previous Frame, Batch, and ranges. Width admission during pending Buffer Search input measured 4,568,750 ns median and 5,617,791 ns p95 on the source fixture. Many-input Draft deletion admission measured 9,660,584 ns median and 10,612,125 ns p95. The later admission-latency and final benchmark work remain open.

New tests compare indexed lookup with linear lookup across wrapped source rows, overlapping ReviewBody spans, typed owners, and collapsed footers. They also cover empty Lines, missing owners, content-equal Section paths, Selection, Count, viewport offsets, and File-header boundaries. A worker admission test changes the cursor and Selection after the worker finishes. Existing tests cover saved Buffer Search navigation, Selected Version fallback, File Enrichment restoration, Draft deletion navigation, stale Frames, cancellation, Session replacement, and allocation failures.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 940 tests. The Standards and Spec self-review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is the separate measurement of initial Session publication.

## Initial Session Frame staging

Initial Session construction measured 47,383,875 ns median and 58,037,000 ns p95 on the 131,072-Line source fixture before staging. The measurement excludes Session acquisition, Diff parsing, and Hunk emphasis preparation. It includes PendingReview loading, initial Buffer construction, visual rows, the File Tree, search indexes, the search corpus, and input snapshots.

`session_loaded` now prepares private Candidate Session inputs and queues `prepare_session`. The worker constructs the complete initial Frame and its search data. PendingReview loading and ScopeProjection resolution stay on the terminal thread before handoff. Candidate arenas use a thread-safe allocator. Publication transfers subsequent interaction allocations to the terminal allocator while keeping each arena's original backing allocator.

The published Session and Session Epoch stay unchanged while preparation runs. Admission checks the command id, replacement intent, geometry, preferences, and persisted-review revision. Changed geometry or Draft state queues another preparation against current inputs. Successful admission restores navigation through the existing index and publishes the Candidate Session before releasing the previous Session. Failed preparation preserves the previous Session and its Frame. Review switching, selecting the current Review, and shutdown release queued candidates and reject issued candidates.

The benchmark now reports synchronous construction, terminal dispatch, worker construction, and terminal admission separately. `zig build bench-buffer-search -- 4096 --initial-session` runs only these stages. The regular benchmark also reports them. Each run uses nine ReleaseFast samples without concurrent build or test work. Both fixtures contain 16 Files and no Drafts or ReviewCards. Geometry is 100 terminal columns and 30 rows. Each sample starts without a published Session. The benchmark checks visual-row and search-Candidate counts against the synchronous control.

| Stage | 1,024 Lines median ns | 1,024 Lines p95 ns | 131,072 Lines median ns | 131,072 Lines p95 ns |
| --- | ---: | ---: | ---: | ---: |
| Synchronous construction control | 335,458 | 620,292 | 52,766,000 | 62,167,125 |
| Terminal dispatch | 4,125 | 23,625 | 8,917 | 23,542 |
| Worker construction | 385,875 | 445,750 | 63,381,833 | 68,818,500 |
| Terminal admission | 1,375 | 22,209 | 4,500 | 28,166 |

The small fixture contains 16,232 Diff bytes. The large fixture contains 2,193,960 Diff bytes. The commands are `zig build bench-buffer-search -- 32 --initial-session` and `zig build bench-buffer-search -- 4096 --initial-session`. The large fixture's initial construction moves off the terminal thread. These first-publication measurements exclude release of a previous Frame. They do not bound PendingReview loading or ScopeProjection resolution with many Drafts. Startup with `Boot.initial` still constructs its Frame before the terminal loop starts.

Tests cover first publication, delayed replacement, geometry retries, command-family correlation, and Draft state changes during a Durable Operation. They also cover queued and issued cancellation, current-Review reuse, worker allocation failure, launch failure, and closed completion sinks before and after construction. Existing replacement tests complete the new worker command through the same completion seam. They retain refresh, Reconciliation, navigation, Composer, File Enrichment, and Buffer Search behavior.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 947 tests. The Standards and Spec self-review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is removal of reachable synchronous search rebuild fallbacks.

## Synchronous search rebuild fallback removal

Production dispatch no longer calls synchronous Buffer rebuild controls. Escape queues restoration when disclosure keys change. An unchanged Escape transfers the saved search baseline without construction. Query clearing and scan admission use their worker handoff decisions once. An unchanged target keeps the current Frame. Those paths no longer repeat disclosure lookup or fall back to complete Batch projection.

The synchronous reference functions now use explicit `Control` names. `prepareBufferControlForFile` rejects production callers at compile time. `scanBufferSearchControl` has the same restriction. The benchmark executable declares `buffer_search_benchmark` to enable its controls. Tests also retain the controls. A temporary call from `openBufferSearch` confirmed that `zig build` rejects a production control call. The temporary call was removed before the final build.

New tests disable terminal allocations during unchanged scan admission, Query clearing, and Escape. They check worker-range transfer, accepted Batch retention, disclosure-baseline retention, and unchanged navigation and visual rows. Restoration failure tests cover all three transitions. Each failure preserves the earlier Frame and baseline without synchronous recovery. A later worker request restores the Frame. Existing tests cover stale completions, Query generations, Enter, Count, cancellation, Session replacement, and allocation failures.

`zig build`, formatting checks, and `zig build test --summary all` pass. The full suite contains 949 tests. `zig build test-search-kernel --summary all` passes with 103 tests. `zig build bench-buffer-search -- 32` passes its worker and synchronous-control checks. The Standards and Spec self-review found no remaining findings for this item. The ticket remains `ready-for-agent`. The next remaining item is the benchmark extension and final latency evidence.

## Final latency evidence

The benchmark now supports `--final-evidence`. This mode measures the final search paths without repeating older Draft mutation and Review Search destination measurements. The default mode retains those measurements.

Both 1,024-Draft fixtures now exercise Query edits before and after scan launch, stale completion admission, and resize during pending input. Each Draft contains one `needle` at its final authored bytes. The benchmark checks the newest Query, occurrence count, complete Frame, projected-range count, saved navigation, and Escape restoration. It also measures headless painting with many ReviewCards. Cache focus now exercises a Query edit after worker construction. Admission rejects the earlier cache Frame before a retry publishes the changed cache and newest Query together.

[Final evidence](../final-latency-evidence.md) records fixture sizes, median latency, p95 latency, commands, and measurement limits. The original 4,096-Line fixture now measures opening at 40,666 ns p95, compared with 8,654,375 ns in the baseline. Completion admission measures 12,209 ns p95, compared with 94,588,583 ns. The 131,072-Line fixture measures Query edits at 28,042 ns p95 and resize dispatch at 5,125 ns p95. The many-input fixture measures worker handoff at 10,125 ns p95 and navigation restoration at 2,000 ns p95. Its complete resize admission measures 13,255,834 ns p95.

`zig build bench-buffer-search -- 128 --final-evidence` and `zig build bench-buffer-search -- 4096 --final-evidence` pass. `zig build`, formatting checks, and `git diff --check` pass. `zig build test --summary all` passes with 949 tests after the implementation changes. The Standards and Spec self-review found no remaining findings. All remaining-work items are complete. The ticket is `resolved`.
