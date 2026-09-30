# 15 — Eliminate Remaining Buffer Search Input Stalls

**What to build:** Buffer Search input remains responsive on large Pull Requests while opening search, typing rapidly, admitting scan completions, revealing hidden matches, and projecting highlights.

**Blocked by:** 11 — Add Buffer Search.

**Status:** ready-for-agent

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
- [ ] Remove Sidebar-triggered full Buffer rebuilds. Cover Directory expansion, Directory collapse, and active-File reveal. `revealActiveFile` currently rebuilds even when it removes no collapsed Directories. Update the File Tree without rebuilding unchanged DiffPane content, or stage the complete Frame when content must change.
- [ ] Stage Review Search destination Buffer builds. Cover source occurrences, ReviewBody occurrences, and the second build that reveals a hidden Fold. `openReviewSearchOccurrence` still builds on the terminal thread, including after File Enrichment publication.
- [ ] Stage disclosure restoration when Buffer Search starts after Review Search. `openBufferSearch` still calls `prepareBuffer` when Review Search owns temporary disclosures.
- [ ] Stage File Enrichment cache-focus and lease-release Frame changes. Completion Frames already use workers, but `focusEnrichment`, `finishSearchLease`, and `releaseReviewSearchHolds` can rebuild synchronously after eviction. Keep cache changes and Frame publication atomic.
- [ ] Index hidden Search Occurrence navigation and disclosure lookup. `searchOccurrenceNavigationRow`, `requiredSearchDisclosure`, and their helpers still walk visual rows, Buffer rows, Hunks, Threads, or Draft chains. Cover hidden `n`, `N`, Count, Query clearing, and the scan-to-disclosure handoff.
- [ ] Bound active-occurrence retention and origin selection during completion admission. `retainedEditedSearchIndex` and `firstSearchOccurrenceAtOrAfter` still walk complete Batches on the terminal thread. `searchFromInactiveRow` also walks Batches when traversal starts without an active occurrence.
- [ ] Bound navigation restoration during worker Frame admission. `frame.restoreNavigation` still searches complete visual-row arrays for the cursor and Selection. Version restoration and File-header navigation also need checks on large Frames.
- [ ] Measure initial Session publication separately. `Published.create` still builds the initial Buffer, visual rows, File Tree, source-coordinate projection, and search corpus on the terminal thread. Move this work into Candidate Session preparation if the measurement shows an input stall.
- [ ] Remove reachable synchronous search rebuild fallbacks after the paths above use workers. `prepareBufferForFile` still builds the corpus, scans accepted and input Queries, and projects complete Batches. Keep synchronous benchmark controls distinct from production dispatch. Add transition and failure tests for each newly staged path.
- [ ] Extend the latency benchmark and record final evidence. Cover many Draft bodies, many ReviewCards, nested Directories, cache eviction, hidden occurrence traversal, and resize during pending input. Measure worker handoff and navigation restoration separately. Record fixture sizes, median latency, and p95 latency. Run `zig build test --summary all` after the implementation changes, then update this checklist and the ticket status.

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
