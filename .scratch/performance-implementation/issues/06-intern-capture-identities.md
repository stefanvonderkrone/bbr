# Intern Capture identities

Type: task
Status: resolved
Blocked by: 05

## Question

How will Action 4 represent Capture names as query-local `u16` identities, remove per-Span string allocation, and resolve each identity through a prebuilt Theme color table?

## Answer

Each `RuntimePackage` now classifies its Capture names once. The package stores a table of query-local `u16` identities and compact Theme roles. Each Span copies the identity and role instead of allocating a Capture name. Presentation resolves the role with one switch and does no Capture string scans per frame. Queries with more than 65,536 Captures fail before an identity can overflow.

Three isolated baseline runs from the unchanged revision measured a 13,083,958 ns median of medians. Three changed runs measured 12,774,542 ns, a 2.4% reduction. The median p95 fell from 13,977,666 ns to 13,170,125 ns, a 5.8% reduction. Timed allocations fell from 26,105 to 1,881, a 92.8% reduction. Peak bytes fell from 2,917,205 to 1,606,520, a 44.9% reduction. Retained bytes fell from 7,782,576 to 4,193,570, a 46.1% reduction. The representation change gives the benchmark a new stable checksum, `6d8e7cf7407da187`.

The changed Time Profiler trace ran for 14.16 seconds. Its hot stacks remain tree-sitter parsing, query cursor work, predicate RE2 matches, and the dense label planes in `highlightWithPackage`. Capture-name allocation is absent. CPU Counters provides the hardware evidence in `../profiles/highlight-capture-id-changed-counters.trace`. The Time Profiler asset is `../profiles/highlight-capture-id-changed-time.trace`. The macOS Allocations template did not finalize after four attempts, including one repetition and a 15-second time limit. The benchmark allocator supplied the allocation and byte evidence above.

`zig build test --summary all` passes all 699 tests. `zig fmt --check build.zig src/highlight src/main.zig src/benchmark tests/grammar_cli_integration.zig` and `git diff --check` pass.
