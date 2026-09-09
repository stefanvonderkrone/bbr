# Own a compact cell row

Type: task
Status: resolved
Blocked by: 22

## Question

If Action 22 passes the P2 gate, will an owned struct-of-arrays cell row and one vaxis blit improve paint time enough to replace the current Window writes safely?

## Answer

Do not add an owned struct-of-arrays cell row. Vaxis already owns a contiguous `[]Cell` screen. Its public `Window` API has no row blit, so another row would duplicate storage and rebuild `Cell` values before the same screen writes.

Use `Window.fill` for each full row instead. Vaxis implements this operation with `@memset`. The smallest production change replaces the checked `Window.writeCell` loop in `fillRow` and leaves all later text and style writes unchanged.

The same-host ReleaseFast baseline measured a 2,202,250 ns median and a 2,317,666 ns p95. Three changed runs measured medians from 1,849,667 ns to 1,897,083 ns and p95 values from 1,915,750 ns to 1,938,375 ns. The slowest changed median is 13.9% faster than the baseline. All runs kept checksum `31e6099593c99148`, zero allocations, and zero peak bytes.

Keep `win.clear()`. A Presentation Frame can leave unused Pane rows, so removing the clear can retain cells from the prior frame.

The 12.38-second Time Profiler trace (`cell-row-changed-time.trace`) shows `Window.fill`, gutter writes, and checksum work after the change. The 10.37-second CPU Counters trace (`cell-row-changed-counters-5000.trace`) records the post-change hardware counters. The Allocations trace (`cell-row-changed-allocations.trace`) confirms the stage does not add frame allocations.

`zig build test --summary all` passes all 709 tests. `zig fmt --check src/tui/render.zig src/benchmark/frame_paint.zig` and `git diff --check` pass.
