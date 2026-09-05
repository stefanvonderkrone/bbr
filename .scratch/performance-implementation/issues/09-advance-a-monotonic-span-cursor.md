# Advance a monotonic Span cursor

Type: task
Status: resolved
Blocked by: 01, 29

## Question

How will Action 7 stop `lineSpans` from rescanning Spans from index zero for each Line while preserving Unified and SideBySide output?

## Answer

Keep one old-side and one new-side Span cursor in the Buffer's `Weave`. Reset both cursors at each File boundary. Each cursor advances only to the next requested Line, so all Spans are scanned once per File. Unified and SideBySide keep their existing side-selection rules.

Four ReleaseFast benchmarks cover a 5,000-Line File with sparse and dense Spans in both Layouts. Their checksums include every LineDecoration. The checksums stayed stable before and after the change.

Dense Unified median latency fell from 3,010,167 ns to 147,916 ns, a 95.1% reduction. Dense SideBySide fell from 3,163,958 ns to 158,083 ns, a 95.0% reduction. Sparse Unified fell from 273,709 ns to 111,292 ns. Sparse SideBySide fell from 287,584 ns to 120,000 ns. Allocation counts and peak bytes did not change.

The 13.27-second [baseline Time Profiler trace](../profiles/span-projection-baseline-time.trace) shows the zero-based `lineSpans` scan in the hot stack. The 13.09-second [changed Time Profiler trace](../profiles/span-projection-changed-time.trace) shows LineDecoration and Buffer emission as the remaining hot work. The [baseline CPU Counters trace](../profiles/span-projection-baseline-counters.trace) and [changed CPU Counters trace](../profiles/span-projection-changed-counters.trace) provide hardware evidence for an instruction-throughput workload. Harness ceiling rates remain calibration proxies.

The macOS Allocations template did not finalize before timeout for the baseline, changed, or single-repetition runs. The benchmark allocator still confirms unchanged allocation behavior.

`zig build test --summary all` passes all 700 tests. `zig build bench`, `zig fmt --check build.zig src/benchmark src/tui/buffer.zig`, and `git diff --check` pass.
