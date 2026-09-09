# Shrink Line and Span layouts

Type: task
Status: resolved
Blocked by: 13

## Question

If Action 14 passes the P1 gate, how will compact Line numbers, Span offsets, and Capture identities improve density without reducing accepted file size or changing semantics?

## Answer

Store absent `Line` numbers as zero because file line numbers start at one. `oldNo` and `newNo` expose the existing optional semantics where callers need them. Store `Span` offsets as `u32`, which matches the existing Highlighting limit of `maxInt(u32)` bytes. `Capture` keeps its existing `u16` identity and byte-sized Theme role.

`Line` shrank from 40 to 32 bytes. Each 50,000-Line list now needs 1,600,000 bytes instead of 2,000,000 bytes. `Span` shrank from 24 to 16 bytes. Each dense 5,000-Span list now needs 80,000 bytes instead of 120,000 bytes. Tests lock both sizes and verify the absent-number conversion.

The 300-File, 50,000-Line Diff parse retained 2,105,062 bytes instead of 3,178,874 bytes, a 33.8% reduction. Its repeated median was 337,792 ns against the 331,542 ns baseline. Dense Unified Span projection measured 153,750 ns against the 152,666 ns baseline. These small latency changes are not material, and both checksums stayed stable.

Time Profiler traces kept Diff parser list growth, LineDecoration, and Buffer emission in the hot stacks. Allocations traces captured the arena and list allocations. CPU Counters classified both stages as instruction-delivery limited. Useful work changed from 5.55% to 5.41% for Diff parsing and from 1.99% to 2.34% for Span projection.

Profile assets:

- Baseline Line Time Profiler: `line-span-baseline-line-time.trace`
- Baseline Line Allocations: `line-span-baseline-line-allocations.trace`
- Baseline Line CPU Counters: `line-span-baseline-line-counters.trace`
- Compact Line Time Profiler: `line-span-compact-line-time.trace`
- Compact Line Allocations: `line-span-compact-line-allocations.trace`
- Compact Line CPU Counters: `line-span-compact-line-counters.trace`
- Baseline Span Time Profiler: `line-span-baseline-span-time.trace`
- Baseline Span Allocations: `line-span-baseline-span-allocations.trace`
- Baseline Span CPU Counters: `line-span-baseline-span-counters.trace`
- Compact Span Time Profiler: `line-span-compact-span-time.trace`
- Compact Span Allocations: `line-span-compact-span-allocations.trace`
- Compact Span CPU Counters: `line-span-compact-span-counters.trace`

`zig build bench`, `zig build test --summary all`, `zig fmt --check build.zig src/benchmark src/diff src/highlight src/review src/tui`, and `git diff --check` pass. The test suite reports 707 passing tests.
