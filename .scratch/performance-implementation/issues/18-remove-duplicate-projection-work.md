# Remove duplicate projection work

Type: task
Status: resolved
Blocked by: 13

## Question

If Action 15 passes the P1 gate, which duplicate tallies and unused width measurements can bbr delete while preserving File Tree and Presentation Frame output?

## Answer

`Buffer.file_tallies` is now the only per-File comment and Draft count. File Tree consumes that array instead of scanning all Threads and Drafts for every File. This also makes Buffer and File Tree use the same ScopeProjection-aware counts.

`VisualRow` and `VisualHalf` no longer store `measured_cells`. No production code read either field. Presentation Frame projection now measures text only when wrapping needs cell widths.

On the Apple M5 Pro ReleaseFast host, `file_tree_tallies_2000` fell from 2,684,125 ns median to 105,333 ns. This is a 96.1% reduction. Its checksum stayed `a25e7fee2d9e9589`.

`visual_rows_unwrapped_50000` fell from 500,625 ns median to 345,250 ns. This is a 31.0% reduction. `VisualRow` shrank from 232 to 208 bytes. Peak bytes fell from 11,739,200 to 10,524,800, and retained bytes fell from 17,608,848 to 15,787,248. Its checksum stayed `ee278cfb4c01b2bb`.

The File Tree Time Profiler baseline shows the removed count scans. The changed profile shows path-tree construction, sorting, formatting, and allocation as the remaining work. The Presentation Frame changed profile shows row construction and copies, with no text-width scan. CPU Counters provide hardware evidence that instruction delivery remains the main limit. Allocations profiles confirm the smaller Presentation Frame rows.

Profile assets:

- File Tree baseline Time Profiler: `projection-tallies-baseline-time-final.trace`
- File Tree baseline Allocations: `projection-tallies-baseline-allocations-final.trace`
- File Tree baseline CPU Counters: `projection-tallies-baseline-counters.trace`
- File Tree changed Time Profiler: `projection-tallies-changed-time.trace`
- File Tree changed Allocations: `projection-tallies-changed-allocations.trace`
- File Tree changed CPU Counters: `projection-tallies-changed-counters.trace`
- [Presentation Frame baseline profiles](16-shrink-visual-row-hot-data.md#answer)
- Presentation Frame changed Time Profiler: `projection-width-changed-time.trace`
- Presentation Frame changed Allocations: `projection-width-changed-allocations.trace`
- Presentation Frame changed CPU Counters: `projection-width-changed-counters.trace`

`zig build bench`, `zig build test --summary all`, `zig fmt --check build.zig src/benchmark src/tui`, and `git diff --check` pass. The test suite reports 707 passing tests.
