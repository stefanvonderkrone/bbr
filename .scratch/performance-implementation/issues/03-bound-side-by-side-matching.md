# Choose and bound side-by-side matching

Type: task
Status: resolved
Blocked by: 02

## Question

Which side-by-side matching algorithm gives the best measured performance within the behavior contract? Implement that algorithm with bounded scratch storage, enforce the measured work limit, preserve exact reconstruction below the limit, and use the chosen simpler pairing above it.

## Answer

Keep the weighted sequence-alignment algorithm below a 131,625 work-unit limit. It preserves the existing similarity threshold, exact-pair preference, earliest-pair tie break, and stable reconstruction. Reusable lexical scratch storage removes the per-Line-pair page allocations. A separate bounded scratch arena now owns the similarity and match matrices instead of the Buffer arena.

The work count is the removed-Line by added-Line area plus the product of each side's total lexical-part count. Above the limit, pair removed and added Lines by index and leave extra Lines unmatched. A regression test checks deterministic index pairing and exact Line reconstruction.

ReleaseFast measurements used Zig 0.16.0 on an Apple M5 Pro host with Zig's `apple_m1` compilation target. The harness used 15 samples and two warmups. Exact 45x45 matching measured 319,750 ns p95 and 286,541 ns p95 in repeated runs. Exact 50x50 matching measured 517,708 ns p95, so 45x45 is the largest measured fixture below the 332,137 ns cap. The benchmark reports a 99.34% gap between area-unit throughput and the instruction calibration. This is a relative proxy, not a hardware limit, because area units do not equal CPU instructions. Hardware counters are required to measure a defensible instruction ceiling.

The required replacement-block benchmarks all stay below the cap after the limit applies:

- 10x10 exact: 19,917 ns median, 23,417 ns p95, checksum `1ed51541671ea621`. The prior implementation measured 507,583 ns median and 688,375 ns p95 with the same checksum.
- 100x100 index fallback: 27,625 ns median, 30,000 ns p95, checksum `3c6b82298c055d9e`.
- 500x500 index fallback: 140,417 ns median, 146,375 ns p95, checksum `5cd31b929822a442`.

`zig build test --summary all` passes all 697 tests.
