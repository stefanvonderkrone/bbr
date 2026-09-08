# Limit or cache viewport wrapping

Type: task
Status: resolved
Blocked by: 13

## Question

If Action 16 passes the P1 gate, should bbr wrap only the viewport with overscan or cache complete wrap results, and how will width, Scope, Layout, and Buffer changes invalidate them?

## Decision

Keep the complete wrap result for a height-only resize. A width change rebuilds the Presentation Frame because it can change every wrap boundary. Scope, Layout, and Buffer changes use the existing rebuild paths and replace the cached visual rows.

Do not add viewport-only wrapping. Removing copied `LineDecoration` slices from each wrapped `VisualRow` removes the measured allocation cost without adding overscan rules or partial-result state. Rendering clips the original decoration runs to each visual row.

## Evidence

Three ReleaseFast runs of `visual_rows_wrapped_50000` measured 3.30 ms, 3.32 ms, and 3.38 ms median latency. The baseline range was 4.65 ms to 5.22 ms, so the slowest changed run is at least 27% faster than the fastest baseline run. Allocations fell from 120,026 to 10, and peak bytes fell from 58,035,296 to 27,031,680. The checksum stayed `7d7313cb2c24ebce`.

The 19.88-second [changed Time Profiler trace](../profiles/viewport-wrap-changed-time.trace) and the 18.64-second [changed CPU Counters trace](../profiles/viewport-wrap-changed-counters.trace) each ran 4,000 repetitions. The macOS Allocations template did not finalize within 180 seconds for either 4,000 or 10 repetitions. The benchmark allocator supplies the allocation evidence.

`zig build test --summary all` passes all 708 tests. Render tests cover decoration runs that cross a unified wrap boundary and side-by-side continuation rows.
