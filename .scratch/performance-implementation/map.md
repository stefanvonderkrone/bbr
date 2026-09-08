# Implement the measured performance plan

Label: wayfinder:map

## Destination

A measured, faster `bbr` with every P0 action implemented and each P1 or P2 action either implemented with supporting benchmark evidence or rejected with recorded evidence. All accepted changes preserve correctness and pass the test suite.

## Notes

- This map carries execution. A task can change code, tests, benchmarks, and documentation when it resolves one action from `PERFORMANCE.md`.
- Primary domains: Diff, Highlighting, Presentation, Bitbucket, and Git. Read `CONTEXT-MAP.md` and each affected `CONTEXT.md` before a change.
- Use `zig` and `ponytail` for every implementation task. Use `diagnosing-bugs` when a benchmark or regression needs diagnosis.
- Use ReleaseFast benchmarks on the current macOS host as the first baseline. Record enough host data to reproduce each comparison, but keep production code portable.
- Keep an optimization only when repeated measurements show a clear gain, output checksums stay stable, and related benchmarks show no material regression.
- Before each optimization, capture stage-isolated ReleaseFast CPU and memory profiles. Run the stage long enough for stable samples, record the hot stacks and allocation or VM call sites, then repeat the same profiles after the change.
- On macOS, use `xctrace` with Time Profiler or CPU Profiler and Allocations. Keep benchmark code and production code portable.
- Treat the harness instruction and memory rates as host calibration proxies. Use hardware-counter evidence when classifying a stage as instruction-throughput-bound or memory-bandwidth-bound.
- For each hot stage, identify whether instruction throughput or memory bandwidth sets the useful hardware ceiling. Report the measured gap to that ceiling and optimize the largest supported gap.
- Preserve current output for normal inputs. For pathological replacement blocks or minified lines, first measure a time budget. Inputs above that budget keep all text but use deterministic simpler pairing or whole-line emphasis.
- For Diff work, compare suitable replacement algorithms. Do not keep the current dynamic-programming or LCS algorithm when another algorithm gives better measured performance within the behavior contract.
- Keep one `PERFORMANCE.md` action per execution ticket. A profile gate can close a later ticket without implementation when evidence does not support the action.

## Decisions so far

- [Build the benchmark harness](issues/01-build-benchmark-harness.md) — `zig build bench` now provides deterministic ReleaseFast stage measurements, allocation data, stable checksums, and host-calibrated ceiling gaps.
- [Set the pathological diff time budget](issues/02-set-pathological-diff-time-budget.md) — Each algorithm gets a 332,137 ns p95 cap; benchmarks derive input limits, then deterministic fallbacks preserve all Lines.
- [Choose and bound side-by-side matching](issues/03-bound-side-by-side-matching.md) — Weighted matching uses reusable bounded scratch through 131,625 work units, then index pairing keeps required fixtures below the p95 cap.
- [Choose and bound the intraline diff](issues/04-bound-intraline-lcs.md) — Compact-direction LCS runs through 250,000 lexical-part products, then whole-line emphasis bounds larger Lines.
- [Build repeatable performance profiles](issues/29-build-repeatable-performance-profiles.md) — Repeat mode now gives each P0 stage stable Time Profiler, Allocations, and CPU Counters runs with checksum checks.
- [Cache Grammar runtime packages](issues/05-cache-grammar-runtime-packages.md) — Immutable packages move query, predicate, RE2, Capture, and UserGrammar setup out of worker calls, cutting warm Highlighting median latency by 23.4%.
- [Intern Capture identities](issues/06-intern-capture-identities.md) — Query-local identities remove per-Span Capture names, cutting Highlighting allocations by 92.8% and median latency by 2.4%.
- [Merge Capture intervals](issues/07-merge-capture-intervals.md) — Sorted Capture intervals preserve Span output while cutting Highlighting peak scratch bytes by 15.8%.
- [Index Buffer rows by File](issues/08-index-buffer-rows-by-file.md) — Compact per-File row starts replace duplicate full-prefix scans with binary lookup, cutting 1,000 bottom-row lookups by at least 3,914x.
- [Advance a monotonic Span cursor](issues/09-advance-a-monotonic-span-cursor.md) — Per-File side cursors scan each Span once, cutting dense 5,000-Line projection latency by 95% in both Layouts.
- [Index Comment anchors](issues/10-index-comment-anchors.md) — Transaction-local Anchor, Reply, and disclosure indexes preserve Buffer output while cutting 2,000-item projection latency by at least 98.8%.
- [Add the ASCII cell-width fast path](issues/11-add-ascii-cell-width-fast-path.md) — SIMD printable-ASCII detection and batched vaxis width measurement preserve terminal geometry while cutting one MiB ASCII measurement latency by 99.86%.
- [Remove frame paint allocation](issues/12-remove-frame-paint-allocation.md) — Static gutter glyphs and first-pass cursor styling remove all measured frame allocations and cut median paint latency by 6.7%.
- [Select P1 actions from the P0 profile](issues/13-select-p1-actions.md) — Actions 11, 13, 14, 15, 16, and 18 pass; measured costs reject Actions 12 and 17.
- [Release Highlighter scratch memory](issues/14-release-highlighter-scratch-memory.md) — File Enrichment releases per-side scratch, retains exact Spans, and caps retained Buffer and frame arena capacity.
- [Shrink VisualRow hot data](issues/16-shrink-visual-row-hot-data.md) — Buffer-indexed cold Rows and byte-sized RowKind indexes cut 50,000-row Presentation Frame memory by 31.0% and median latency by 16.2%.
- [Shrink Line and Span layouts](issues/17-shrink-line-and-span-layouts.md) — Zero-sentinel Line numbers and `u32` Span offsets cut their layouts by 20% and 33% without a material latency change.
- [Remove duplicate projection work](issues/18-remove-duplicate-projection-work.md) — Shared File tallies and removal of unused width data cut File Tree latency by 96.1% and unwrapped Presentation Frame latency by 31.0%.
- [Limit or cache viewport wrapping](issues/19-limit-or-cache-viewport-wrapping.md). Height-only resize reuses complete visual rows. Render-time decoration clipping cuts full-wrap median latency by at least 27% and allocations from 120,026 to 10.

## Not yet specified

- A release-level end-to-end latency target may become useful after stage timers expose the dominant costs.
- Benchmark evidence may reveal a bottleneck not listed in `PERFORMANCE.md`. Add a ticket only when the question and proof are precise.

## Out of scope

- Optimizations that fail the measured evidence gate.
- A required cross-platform benchmark matrix. The first baseline uses the current macOS host.
- The non-actions listed in `PERFORMANCE.md`, unless new profile evidence overturns their stated reasons.
- Product behavior unrelated to review performance.
- [Cache ReviewBody and File line starts](issues/15-cache-review-bodies-and-line-starts.md) — Measured rebuild costs are too small to justify cache state and invalidation rules.
- [Cache Highlighting results](issues/20-cache-highlight-results.md) — No measured Session workload establishes a useful cache hit rate.
