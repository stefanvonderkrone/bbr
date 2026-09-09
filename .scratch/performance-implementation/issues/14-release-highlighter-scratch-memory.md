# Release Highlighter scratch memory

Type: task
Status: resolved
Blocked by: 13

## Question

If Action 11 passes the P1 gate, how will File Enrichment separate Highlighter scratch memory from retained Spans and cap retained Buffer and frame arena capacity?

## Comments

The Highlighter now accepts separate result and scratch allocators. File Enrichment gives each side a temporary scratch arena and releases it before it records retained bytes. Tree-sitter builds Capture intervals and the growing Span list in scratch, then copies only the exact final Span slice into the side's result arena.

The ReleaseFast JavaScript benchmark retained 118,054 bytes at 4 KiB, 3,748,686 bytes at 100 KiB, 21,706,318 bytes at 1 MiB, and 49,103,510 bytes at 2 MiB before the change. It now retains 35,148, 871,464, 8,922,936, and 17,845,356 bytes. These results reduce retained bytes by 70.2%, 76.8%, 58.9%, and 63.7%. Median latency has no material regression, and every checksum is unchanged.

At 2 MiB, all BuiltInGrammar results now retain 4,718,532 to 34,688,208 bytes. The pre-change range was 19.7 MiB to 119.1 MiB. A File Enrichment test also proves that 1 MiB of synthetic Highlighter scratch does not enter the retained side capacity.

Buffer arenas now use a 64 MiB retained-capacity limit. The frame arena uses a 4 MiB limit. Both use Zig's `ArenaAllocator.reset(.retain_with_limit)` behavior, and ArenaRing has a small-limit regression test.

The 800-repetition Time Profiler runs lasted 11.75 seconds before the change and 11.31 seconds after the final change. Tree-sitter parsing, query cursor work, predicate checks, Capture collection, and Span merging remain the hot stacks. CPU Counters completed for both runs and provide the hardware evidence. Both Allocations attempts failed to finalize within 180 seconds, so the benchmark allocator supplies the peak and retained-byte evidence.

Profile assets are `../profiles/highlight-scratch-baseline-{time,counters}.trace` and `../profiles/highlight-scratch-final-{time,counters}.trace`. `zig build bench`, `zig build test --summary all`, `zig fmt --check build.zig src/benchmark src/highlight src/tui`, and `git diff --check` pass. The test suite reports 705 passing tests.

## Answer

File Enrichment releases all Highlighter scratch after each side and retains only the blob and exact final Spans. Buffer arenas retain at most 64 MiB each, and the frame arena retains at most 4 MiB after a reset.
