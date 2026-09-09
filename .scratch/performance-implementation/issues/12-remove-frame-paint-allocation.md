# Remove frame paint allocation

Type: task
Status: resolved
Blocked by: 01, 29

## Question

How will Action 10 remove per-column gutter formatting allocation and redundant row reads and writes without giving vaxis borrowed stack data that expires before render?

## Answer

Format each unified or side-by-side gutter into a fixed stack buffer, then translate its bytes to static digit and space glyphs as cells are written. Vaxis borrows only static strings, so no stack slice survives the draw call. Apply the cursor-row background to a row-specific Theme before drawing. This removes the second full-row `readCell` and `writeCell` pass and prevents a selected cursor row from receiving the tint twice.

The new `frame_paint_1000_rows` ReleaseFast benchmark models 1,000 selected rows at 160 columns. Its stable checksum is `31e6099593c99148`. Median latency fell from 2,392,291 ns to 2,231,292 ns, or 6.7%. P95 fell from 2,529,000 ns to 2,366,541 ns. Frame allocations fell from 3,013 and 18,139 peak bytes to zero.

Time Profiler traces ran for at least 10 seconds and are in [`../profiles/`](../profiles/) as `frame-paint-baseline-time-4000.trace` and `frame-paint-changed-time-4500.trace`. CPU Counters traces are `frame-paint-baseline-counters.trace` and `frame-paint-changed-counters.trace`. The macOS Allocations template did not finalize before timeout for baseline, changed, or five-repetition runs. The benchmark allocator supplied the allocation and byte evidence.

`zig build test --summary all` passes all 703 tests. `zig fmt --check build.zig src/benchmark src/tui/render.zig` and `git diff --check` pass.
