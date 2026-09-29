# 15 — Eliminate Remaining Buffer Search Input Stalls

**What to build:** Buffer Search input remains responsive on large Pull Requests while opening search, typing rapidly, admitting scan completions, revealing hidden matches, and projecting highlights.

**Blocked by:** 11 — Add Buffer Search.

**Status:** ready-for-agent

- [x] Add deterministic large-Buffer benchmarks that separately measure opening `/`, query-edit dispatch, worker scanning, completion admission, disclosure rebuilding, range projection, and painting.
- [x] Record median and p95 latency plus fixture size before changing the implementation, and identify which synchronous stages cause the observed stalls.
- [x] Query-edit dispatch performs bounded work and never builds the corpus, scans Candidates, clones a complete Batch, rebuilds disclosures, or projects all ranges.
- [x] Corpus construction is cached, incrementally maintained, or performed as correlated worker work so opening `/` does not stall the terminal loop.
- [x] Presentation allows at most one Buffer Search scan to consume worker capacity at a time and retains only the newest queued Query generation.
- [ ] Completion admission avoids an unbounded full-Batch clone on the terminal thread. Expensive disclosure and range projection work is staged without publishing a partial Frame.
- [ ] Command id, Session Epoch, and Query generation reject stale work. Cancellation, refresh, Review switching, shutdown, launch failure, and allocation failure release every Query, corpus reference, Batch, and staged projection.
- [x] `Enter` while work is pending accepts only the newest completed generation. `Esc`, `n`, `N`, Count, active-occurrence retention, hidden-match reveal, and status reset keep their existing behavior.
- [x] Presentation and runtime tests cover rapid edits before and after worker launch, stale completion ordering, cancellation, failure, and Session replacement.
- [x] The benchmark demonstrates materially lower p95 input latency on the large fixture, and `zig build test --summary all` passes.

## Progress

Commits `4b967b3` and `72a7f35` serialize scans, transfer the worker Batch without a full clone, cache the corpus, and index source rows for range projection. The large-Buffer benchmark runs with `zig build bench-buffer-search`. The full suite passed with 833 tests.

The original work caches the corpus, serializes scans, reuses completed Batches, and indexes source rows. Later changes cache Hunk emphasis per Session, project Buffer Search ranges on the scan worker, and stage Query-driven hidden-match Buffer builds on a worker. The ticket remains open because completion admission still does unbounded projection work on the terminal thread, and other Buffer rebuilds remain synchronous.

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

This fixture is larger than the 32,768-Line runs, but it does not close the ticket. Completion admission still copies all projected ranges and rebuilds the File Tree on the terminal thread. Disclosure Buffer publication also reprojects accepted Buffer Search and Review Search ranges there. Stale `n` and `N` traversal and general Buffer rebuilding remain synchronous. The full suite last passed with 854 tests.

The full suite passed with 854 tests. Tests cover a pending Frame, Enter before completion, rapid Query edits, cancellation, Session replacement, a changed Frame, launch failure, and allocation failure during completion admission.
