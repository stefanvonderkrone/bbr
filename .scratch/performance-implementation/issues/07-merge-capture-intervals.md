# Merge Capture intervals

Type: task
Status: resolved
Blocked by: 06

## Question

How will Action 5 replace per-byte label and priority planes with a precedence-preserving interval merge while differential tests prove byte-for-byte Span equivalence across every Grammar fixture?

## Answer

Highlighting now collects accepted Captures as half-open intervals. It sorts only when the query cursor does not already return source order. The merge groups overlapping intervals, selects the highest pattern index, and uses Capture encounter order to preserve the old equal-priority overwrite rule. It splits winning intervals on newlines and joins adjacent ranges with the same Capture.

The production path no longer allocates or clears the two `u32` arrays that scaled at eight bytes per source byte. On `highlight_javascript_100k`, peak bytes fell from 1,606,520 to 1,353,288, a 15.8% reduction. Retained bytes fell from 4,193,570 to 3,748,686, a 10.6% reduction. Timed allocations stayed at 1,881, and checksum `6d8e7cf7407da187` stayed unchanged.

Three baseline runs measured a 12,765,209 ns median of medians and a 13,010,791 ns median p95. Seven final-layout runs measured a 12,951,209 ns median of medians and a 13,342,708 ns median p95. The 1.5% median and 2.6% p95 changes are below the material-regression gate. The clear measured gain is bounded scratch memory, which scales with Capture count instead of source bytes.

The 13.89-second baseline and 13.95-second changed Time Profiler traces show tree-sitter parsing, query cursor work, predicate checks, and RE2 matches remain hot. The changed trace samples interval collection and merging but no longer samples the removed dense-plane fills. CPU Counters measured 58.04% useful sustainable instruction bandwidth before and 58.06% after, so Highlighting remains instruction-throughput-bound with about a 42% gap to that hardware ceiling. Harness `gap_percent` remains a calibration proxy, not hardware evidence.

Profile assets are `../profiles/highlight-interval-{baseline,changed}-{time,counters}.trace`. The Allocations baseline did not finalize in 180 seconds. The changed Allocations attempt failed to attach before its 15-second limit. The benchmark allocator supplied the allocation and byte evidence.

The differential test runs the old byte-plane reference and the interval merge against valid, invalid, minified, nested, overlapping, and predicate-heavy inputs across every BuiltInGrammar. `zig build test --summary all` passes all 700 tests. `zig fmt --check build.zig src/highlight src/main.zig src/benchmark tests/grammar_cli_integration.zig` and `git diff --check` pass.
