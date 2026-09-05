# Add the ASCII cell-width fast path

Type: task
Status: resolved
Blocked by: 01, 29

## Question

How will Action 9 skip grapheme work for ASCII runs, batch width calls, and prove scalar-equivalent behavior for all lengths, alignments, controls, and UTF-8 cases?

## Answer

`CellMetrics.width` now scans printable ASCII with the target's suggested SIMD width and returns the byte count. Controls, DEL, non-ASCII, and invalid UTF-8 use the adapter. The vaxis adapter measures these inputs with one whole-text `gwidth` call instead of one call per grapheme. Adapters without the optional whole-text callback retain the scalar loop.

Tests compare the SIMD path with scalar measurement for lengths 0 through 64 at offsets 0 through 31. Other tests cover controls, DEL, combining UTF-8, wide UTF-8, an emoji ZWJ sequence, and invalid UTF-8. A production-adapter test compares vaxis whole-text width with its grapheme-by-grapheme result for the same cases.

The ReleaseFast benchmark measures one MiB of deterministic printable ASCII on an Apple M5 Pro with Zig 0.16.0. The scalar baseline median was 17,332,417 ns, and its p95 was 18,189,500 ns. The final SIMD median was 22,792 ns, and its p95 was 25,916 ns. This is a 99.86% median reduction, or about 760 times faster. Both runs reported zero allocations and checksum `100000`.

The 12.21-second [baseline Time Profiler trace](../profiles/cell-width-baseline-time.trace) shows vaxis grapheme iteration and `gwidth` in the hot stack. The 10.26-second [changed Time Profiler trace](../profiles/cell-width-changed-time.trace) shows `isNarrowAscii` as the remaining measured work. The [baseline Allocations trace](../profiles/cell-width-baseline-allocations.trace), [changed Allocations trace](../profiles/cell-width-changed-allocations.trace), [baseline CPU Counters trace](../profiles/cell-width-baseline-counters.trace), and [changed CPU Counters trace](../profiles/cell-width-changed-counters.trace) completed without errors. The harness classified the stage as instruction-throughput work. Its gap changed from 92.61% at baseline to 0% after the change, but this rate is a calibration proxy.

`zig build test --summary all` passes all 703 tests. `zig build bench -- cell_width_ascii_1m`, `zig fmt --check build.zig src/benchmark/main.zig src/benchmark/cell_width.zig src/tui/app.zig src/tui/buffer.zig src/tui/cell_metrics.zig src/tui/frame.zig`, and `git diff --check` pass.
