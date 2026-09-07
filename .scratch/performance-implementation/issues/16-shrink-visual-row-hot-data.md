# Shrink VisualRow hot data

Type: task
Status: resolved
Blocked by: 13

## Question

If Action 13 passes the P1 gate, which measured VisualRow fields belong in the hot contiguous layout, and how will cold Row data remain available through the Buffer?

## Answer

`VisualRow` keeps its Buffer index, `RowKind`, owner, measured width, source range, decoration, continuation state, and optional SideBySide halves. It no longer copies the 104-byte `Row`. Rendering and Actions use `buffer_index` to read the cold `Row` from `Buffer.rows`.

`Buffer.row_kinds` stores one contiguous `RowKind` per `Row`. Tag-only Buffer scans use `Buffer.kindAt`, while `VisualRow.kind` supports hot Presentation Frame scans without reading the cold `Row`.

On the Apple M5 Pro ReleaseFast host, `VisualRow` fell from 336 to 232 bytes. The 50,000-row unwrapped benchmark fell from 604,208 ns median, 17,001,600 peak bytes, and 25,502,448 retained bytes to 506,459 ns median, 11,739,200 peak bytes, and 17,608,848 retained bytes. This cuts median latency by 16.2% and memory by 31.0%.

The wrapped 50,000-row benchmark fell from 5,793,042 ns median, 92,181,216 peak bytes, and 286,734,208 retained bytes to 4,862,041 ns median, 64,437,656 peak bytes, and 198,008,648 retained bytes. Its later execution ticket still owns viewport wrapping or cache policy.

The baseline and changed Time Profiler traces ran `visual_rows_unwrapped_50000` 25,000 times for 36.2 and 33.2 seconds. `frame.buildUnwrappedVisualRows`, `frame.makeVisualRow`, copies, and allocator calls remain the hot stacks. Allocations traces confirm the one large `VisualRow` allocation changed from 17.0 MB to 11.7 MB. CPU Counters classify instruction delivery as the largest limit. Its fraction changed from 0.3935 to 0.3279, while useful work changed from 0.2447 to 0.2672.

Profiles:

- [Baseline Time Profiler](../profiles/visual-row-baseline-time.trace)
- [Baseline Allocations](../profiles/visual-row-baseline-allocations.trace)
- [Baseline CPU Counters](../profiles/visual-row-baseline-counters.trace)
- [Changed Time Profiler](../profiles/visual-row-changed-final-time.trace)
- [Changed Allocations](../profiles/visual-row-changed-final-allocations.trace)
- [Changed CPU Counters](../profiles/visual-row-changed-final-counters.trace)

The baseline and changed output checksum is `adc122d5073b6b50`. `zig build bench`, `zig build test --summary all`, `zig fmt --check build.zig src/benchmark src/tui/benchmark.zig`, and `git diff --check` pass. The test suite reports 705 passing tests.
