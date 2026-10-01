# Final Buffer Search latency evidence

Issue [15](issues/15-eliminate-remaining-buffer-search-input-stalls.md) measures the final worker-based Buffer Search paths.

## Run conditions

- Date: 2026-10-01.
- Host: Mac17,8, 18 physical and logical CPU cores.
- OS: macOS 26.7, build 25G229.
- Compiler: Zig 0.16.0.
- Build: ReleaseFast, native target with macOS 15 deployment minimum.
- Clock: `std.Io.Clock.awake`.
- Samples: nine per stage. Median is the fifth sorted sample. Nearest-rank p95 is the ninth sample.
- Headless painting: 100 columns and 30 rows. Resize targets alternate between 80 and 100 columns with 30 rows.
- Fixtures, controls, and workers run sequentially. No build or test runs overlap the timed benchmark runs.

The successful evidence commands are:

```sh
zig build bench-buffer-search -- 128 --final-evidence
zig build bench-buffer-search -- 4096 --final-evidence
```

The default benchmark retains the older Draft save, Draft mutation, and Review Search destination measurements. `--initial-session` retains its initial-publication-only behavior. `--final-evidence` skips those older mutation and destination measurements. It retains initial publication, source input, worker projection, disclosure transitions, painting, selection, hidden traversal, authored input, Sidebar changes, and cache eviction.

All tables use nanoseconds. The following tables use the successful 4,096-Lines-per-File run unless a section names another run.

## Fixtures

| Fixture | Size |
| --- | --- |
| Original source size, `-- 128` | 16 Files, 4,096 changed Lines, 63,240 Diff bytes, no Drafts or ReviewCards |
| Maximum source size, `-- 4096` | 16 Files, 131,072 changed Lines, 2,193,960 Diff bytes, no Drafts or ReviewCards |
| Maximum source selection Frame | SideBySide, 65,568 visual rows at 80 columns, 131,072 occurrences, 8,388,608 navigation-index bytes |
| Maximum hidden source size | One File, 131,074 Diff Lines, 2,772,562 Diff bytes, one hidden occurrence |
| One-File authored size | One File, two changed Lines, 1,024 Drafts, 4,194,304 body bytes, no AnchorSnapshots or collapsed Directories |
| One-File authored Frame | 1,024 collapsed ReviewCards, 1,026 Candidates, 8,197 visual rows before resize and after the final resize |
| Many-input authored size | 1,024 enriched Files, 2,048 changed Lines, 1,024 Drafts, 4,194,304 body bytes, 4,194,304 AnchorSnapshot bytes |
| Many-input authored Frame | 1,024 expanded ReviewCards, 1,024 collapsed `src/dN` Directories, 3,072 Candidates |
| Many-input navigation Frame | 100,352 visual rows at 80 columns |
| Many-input final resize Frame | 71,680 visual rows at 100 columns |
| Cache size before each sample | All 1,024 Files enriched, 1,024 Drafts, 4,194,304 body bytes, 4,194,304 AnchorSnapshot bytes, 1,024 expanded ReviewCards and collapsed Directories |

Each authored body contains 4,090 `x` bytes followed by `needle`. Literal `needle` produces 1,024 ReviewBody occurrences. This marker replaces six fixture bytes without changing the body size. The shared `src` Directory and its `dN` children exercise nested Directory collapse, expansion, and active-File reveal.

Fixture construction, restoration, interaction setup, and index construction occur outside input and lookup timings. Worker construction remains a separate timed stage. Admission includes release of the earlier Frame, Batch, and ranges.

## Original-size comparison

The baseline uses the same 16-File, 4,096-changed-Line, 63,240-byte source fixture at commit `4b967b3`. Both runs use nine ReleaseFast samples.

| Stage | Baseline median | Baseline p95 | Final median | Final p95 |
| --- | ---: | ---: | ---: | ---: |
| Open `/` | 7,635,584 | 8,654,375 | 13,458 | 40,666 |
| Query edit | 5,291 | 22,875 | 11,875 | 16,583 |
| Worker scan | 44,682,917 | 47,385,334 | 1,201,458 | 1,359,167 |
| Completion admission | 92,566,416 | 94,588,583 | 1,500 | 12,209 |

Opening p95 falls by about 213 times. Completion-admission p95 falls by about 7,747 times. Query-edit p95 falls by about 28 percent. Query-edit median increases, so the evidence does not claim improvement in every statistic. The final scan stage also includes worker projection and navigation-index construction. The baseline ran before painting measurements existed.

## Maximum source fixture

| Stage | Median | p95 |
| --- | ---: | ---: |
| Initial synchronous construction control | 50,663,917 | 69,613,208 |
| Initial terminal dispatch | 9,917 | 12,292 |
| Initial worker construction | 62,263,959 | 66,029,917 |
| Initial terminal admission | 4,208 | 7,667 |
| Open `/` | 285,542 | 375,708 |
| Query edit | 19,250 | 28,042 |
| Scan and worker projection | 51,038,416 | 58,734,583 |
| Separate worker projection | 23,279,250 | 30,103,500 |
| Top-origin scan admission | 2,750 | 12,666 |
| Bottom-origin scan admission | 2,584 | 5,000 |
| Synchronous disclosure construction control | 70,762,125 | 76,537,667 |
| Disclosure worker construction | 107,430,584 | 219,851,334 |
| Disclosure Frame admission | 7,049,792 | 9,228,958 |
| Separate range-projection control | 28,731,041 | 34,580,583 |
| Headless painting | 594,417 | 1,146,333 |
| Layout dispatch | 315,333 | 569,709 |
| Layout worker construction | 779,749,584 | 901,038,416 |
| Layout admission | 5,189,333 | 6,670,541 |
| Resize dispatch during pending input | 3,500 | 5,125 |
| Resize worker construction | 1,012,522,584 | 1,180,872,292 |
| Resize admission | 4,655,333 | 5,618,166 |
| Synchronous resize control | 2,933,257,208 | 3,476,659,750 |

Initial-publication samples start without a published Session. They exclude Session acquisition, Diff parsing, Hunk emphasis preparation, and release of a previous Session. Terminal dispatch includes PendingReview loading and ScopeProjection resolution, but this source fixture has no Drafts.

## Hidden source traversal and restoration

Each hidden traversal sample collapses the accepted occurrence before timing. Worker construction and fixture restoration occur outside the `n`, `N`, and Count dispatch measurements. Count is 999.

| Stage | Median | p95 |
| --- | ---: | ---: |
| Hidden source indexed lookup | 84 | 10,250 |
| Hidden source linear control | 42,750 | 49,792 |
| Hidden `n` dispatch | 12,333 | 13,167 |
| Hidden `N` dispatch | 11,500 | 14,541 |
| Hidden Count dispatch | 12,958 | 15,375 |
| Hidden Query edit | 12,875 | 16,250 |
| Scan-to-disclosure handoff | 6,250 | 8,375 |
| Hidden disclosure worker construction | 70,018,167 | 72,485,542 |
| Hidden disclosure admission | 13,750 | 16,083 |
| Escape dispatch | 17,917 | 21,584 |
| Escape restoration worker | 13,075,167 | 13,911,375 |
| Escape restoration admission | 3,615,750 | 4,132,708 |
| Query clear dispatch | 12,667 | 71,167 |
| Query clear worker | 13,037,833 | 13,782,916 |
| Query clear admission | 3,806,417 | 4,096,667 |

## Worker handoff and navigation restoration

Handoff retains the existing input and disclosure snapshots. Its copy control copies the complete inputs and acquires File leases. Navigation samples place the cursor on the final visual row and the Selection mark on the preceding row. Each linear control checks the complete indexed result.

| Stage | Median | p95 |
| --- | ---: | ---: |
| One-File worker handoff | 1,250 | 5,750 |
| One-File snapshot-copy control | 286,458 | 411,959 |
| Many-input worker handoff | 7,083 | 10,125 |
| Many-input snapshot-copy control | 1,258,000 | 1,567,500 |
| Source navigation restoration | 125 | 19,875 |
| Source navigation linear control | 330,541 | 1,249,208 |
| One-File ReviewBody navigation restoration | 83 | 5,042 |
| One-File ReviewBody navigation linear control | 44,042 | 46,500 |
| Many-input ReviewBody navigation restoration | 583 | 2,000 |
| Many-input ReviewBody navigation linear control | 574,125 | 846,083 |
| One-File ReviewBody disclosure lookup | 125 | 10,334 |
| One-File ReviewBody linear control | 33,250 | 131,291 |
| Many-input ReviewBody disclosure lookup | 583 | 2,167 |
| Many-input ReviewBody linear control | 345,125 | 361,042 |
| Edited-occurrence retention lookup | 4,875 | 6,000 |
| Edited-occurrence retention linear control | 902,625 | 1,741,709 |
| Origin selection lookup | 167 | 5,375 |
| Origin selection linear control | 510,667 | 642,083 |
| Query-refinement admission | 1,855,625 | 2,306,833 |
| Inactive `n` dispatch | 137,542 | 144,000 |
| Inactive `N` dispatch | 143,333 | 153,041 |
| Inactive Count dispatch | 140,917 | 152,166 |

The selection stages use the maximum source Batch. Query-refinement admission also releases its previous Batch and ranges. The separate retention lookup excludes that release cost.

## Authored input and resize

Each sample opens Buffer Search and queues `need`. It replaces that Query with `needl` before scan launch. It then replaces the issued scan's Query with `needle` and requests a width change. The benchmark rejects the earlier scan completion and builds the latest input into the width Frame.

The checks compare Buffer rows, visual rows, occurrence counts, and projected-range counts with the synchronous control. Saved navigation matches the linear restoration control. The benchmark completes any required hidden disclosure work before painting. Escape restores navigation and disclosures before the next sample.

| Stage | One-File median | One-File p95 | Many-input median | Many-input p95 |
| --- | ---: | ---: | ---: | ---: |
| Open `/` | 5,750 | 6,834 | 884,709 | 1,468,666 |
| Edit before scan launch | 4,833 | 7,458 | 5,875 | 13,417 |
| Edit after scan launch | 2,125 | 2,708 | 2,875 | 4,334 |
| Stale scan admission | 1,172,208 | 1,798,000 | 1,207,458 | 1,572,542 |
| Resize dispatch | 3,709 | 4,583 | 3,375 | 6,458 |
| Resize worker construction | 138,549,750 | 151,107,250 | 789,849,834 | 841,271,125 |
| Resize admission | 4,099,625 | 4,733,042 | 8,187,916 | 13,255,834 |
| Synchronous resize control | 208,045,666 | 220,678,292 | 1,195,047,625 | 1,232,486,500 |
| Headless painting | 379,000 | 382,958 | 1,251,916 | 1,541,000 |

Query-edit measurements call the same Query replacement path that key dispatch uses. Stale admission includes disposal of the earlier scan Batch. Complete resize admission includes release of the earlier Frame and search allocations. Those costs exceed the separate indexed navigation lookup.

## Nested Directories

The Sidebar fixture uses the many-input Frame. Collapse and expansion toggle the shared `src` Directory. Hidden active-File reveal opens `src/d0`. Reveal timings exclude File-header lookup and DiffPane movement. Every sample checks that the Buffer, visual rows, and visual-row revision remain unchanged.

| Stage | Median | p95 |
| --- | ---: | ---: |
| Directory collapse dispatch | 1,641,959 | 1,753,792 |
| Directory expansion dispatch | 2,053,208 | 2,165,375 |
| Hidden active-File reveal | 1,429,709 | 1,518,542 |
| Visible active-File reveal | 3,959 | 5,083 |
| Synchronous Buffer control | 711,445,459 | 717,360,542 |

## Cache eviction during input

Cache policy disables inactive caching. Focus evicts the previous focused File. Source-lease release evicts one inactive File. Review Search hold release evicts 1,023 inactive Files.

The focus sample opens Buffer Search with completed `needle` input before eviction dispatch. After the cache worker finishes, the sample changes the Query to `needl`. The old cache completion must preserve the published Frame and cache content. A new scan and cache worker then publish the newest Query and the changed cache together.

| Stage | Median | p95 |
| --- | ---: | ---: |
| Cache focus dispatch | 9,250 | 11,333 |
| Cache focus worker | 758,396,250 | 765,678,083 |
| Cache focus admission after retry | 2,925,834 | 3,764,000 |
| Cache focus synchronous control | 1,145,231,333 | 1,148,795,000 |
| Query edit during pending cache work | 6,959 | 8,000 |
| Stale cache completion admission | 8,279,250 | 9,581,709 |
| Cache retry worker | 756,009,625 | 761,948,666 |
| Source lease release dispatch | 11,792 | 15,000 |
| Source lease release worker | 739,419,042 | 742,847,167 |
| Source lease release admission | 1,419,208 | 2,332,250 |
| Source lease release synchronous control | 711,349,917 | 712,500,625 |
| Review Search hold release dispatch | 573,791 | 1,203,417 |
| Review Search hold release worker | 733,391,833 | 740,958,166 |
| Review Search hold release admission | 9,294,417 | 10,038,250 |
| Review Search hold release synchronous control | 707,470,208 | 774,678,208 |

The benchmark checks the newest Query and its 1,024 occurrences after focus admission. It also checks eviction in both the cache and the replacement input snapshot. Its synchronous control compares the published Buffer and visual-row counts. Stale cache admission includes disposal of the rejected worker Frame.

## Result and limits

The measured input paths no longer include synchronous full Buffer construction. The maximum source fixture measures Query edits at 28 microseconds p95. The many-input fixture measures edits at 13 microseconds p95 before launch and four microseconds p95 after launch. Worker handoff and indexed navigation restoration remain separate measurements.

Complete admission still releases earlier allocations on the terminal thread. The many-input resize measures 13.26 milliseconds p95. Rejected cache Frame disposal measures 9.58 milliseconds p95. Hold-release admission measures 10.04 milliseconds p95. The evidence records those costs rather than treating indexed lookup latency as complete admission latency.

These deterministic runs execute worker functions through the production command and completion seam. They measure stage costs rather than scheduler wait, terminal-event backlog, network latency, or end-to-end key-to-display latency. Nine samples give a coarse p95. These fixture results do not establish a constant latency bound for every Session size. Many-Draft initial publication and durable SQLite persistence are outside these final measurements.

After the implementation changes, the checks pass:

```text
zig build
zig fmt --check src/tui/presentation.zig src/benchmark_buffer_search.zig
git diff --check
zig build test --summary all
Build Summary: 18/18 steps succeeded; 949/949 tests passed
```
