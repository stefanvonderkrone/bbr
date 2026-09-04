# Choose and bound the intraline diff

Type: task
Status: resolved
Blocked by: 02, 29

## Question

Which intraline diff algorithm gives the best measured performance within the behavior contract? Implement that algorithm with bounded work and memory, preserve exact output below the limit, and use whole-line emphasis above it.

## Answer

Use the compact-direction LCS implementation through 250,000 lexical-part products. It keeps two `u32` score rows and one `u8` direction per cell instead of one full `usize` score table. It preserves the previous token matching and tie behavior below the limit. Above the limit, it preserves both Lines and returns one emphasized IntraLineSegment for each non-empty Line.

The benchmark now generates exact lexical-part counts and covers 10, 100, 250, 500, 550, 575, 600, 1,000, 2,000, and 4,000 parts. The old fixture generated twice the count in its name. On the Apple M5 Pro ReleaseFast host, the corrected 500-part full-table baseline measured 336,916 ns median, 343,458 ns p95, 11 allocations, and 2,026,928 peak bytes. The compact implementation's final 500-part run measured 217,167 ns median, 229,958 ns p95, 9 allocations, and 272,928 peak bytes. Four repeated 500-part runs stayed below the 332,137 ns p95 budget. A 550-part exact run reached 422,708 ns p95, so it was rejected as the limit.

The output checksums matched during the exact-algorithm comparison. The final checksum also covers the whole-line fallback marker. Tests cover the fallback in both Diff and unified Buffer projection. `zig build test --summary all` passes all 699 tests. Formatting and `git diff --check` pass.

The post-change [Time Profiler](../profiles/intraline-compact-time.trace), [Allocations](../profiles/intraline-compact-allocations.trace), and [CPU Counters](../profiles/intraline-compact-counters.trace) runs each used 50,000 exact 500-part repetitions with checksum checks. They ran for 11.85, 11.88, and 12.01 seconds. CPU Counters measured 81.21% useful sustainable instruction bandwidth, a measured 18.79% gap. The losses were 10.16% instruction delivery, 4.53% discarded work, and 4.11% instruction processing. This classifies the remaining exact workload as instruction-throughput-bound rather than memory-bandwidth-bound.
