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

## Not yet specified

- A release-level end-to-end latency target may become useful after stage timers expose the dominant costs.
- Benchmark evidence may reveal a bottleneck not listed in `PERFORMANCE.md`. Add a ticket only when the question and proof are precise.

## Out of scope

- Optimizations that fail the measured evidence gate.
- A required cross-platform benchmark matrix. The first baseline uses the current macOS host.
- The non-actions listed in `PERFORMANCE.md`, unless new profile evidence overturns their stated reasons.
- Product behavior unrelated to review performance.
