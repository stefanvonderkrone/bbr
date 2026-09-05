# Index Comment anchors

Type: task
Status: resolved
Blocked by: 01, 29

## Question

How will Action 8 index Thread and Draft anchors and expanded disclosures once per Buffer transaction while preserving every emitted row and tally?

## Answer

`buildWithComments` now builds three transaction-local indexes. `AnchorIndex` groups current inline Threads and root Drafts by path, side, and line. `ReplyIndex` groups reply Drafts by parent. `DisclosureSet` stores expanded disclosure identities. Buffer emission reads these indexes instead of scanning all Threads, Drafts, or expanded disclosures for each Line or ReviewCard. An empty `AnchorIndex` skips per-Line hash lookups.

The ReleaseFast benchmark uses the standard 300-File, 50,000-Line Diff with 0, 100, and 2,000 Threads and Drafts. Each Thread and Draft has an expanded ReviewCard disclosure. Checksums cover row order, ReviewCard identity and text, and File tallies. All checksums stayed stable before and after the change.

The 2,000-item baseline median was 824,888,417 ns. Four changed medians ranged from 9,286,958 ns to 9,816,000 ns, a minimum 98.8% reduction. The 100-item baseline median was 40,815,250 ns. Four changed medians ranged from 3,263,834 ns to 3,469,541 ns, a minimum 91.5% reduction. The empty baseline median was 1,229,833 ns. Three final medians ranged from 1,100,417 ns to 1,132,167 ns, so the index adds no empty-review regression.

The 13.42-second [baseline Time Profiler trace](../profiles/comment-anchors-baseline-time.trace) shows `weaveInline`, `anchorMatchesFile`, `anchorMatchesLine`, and `disclosureExpanded` in the hot stack. The 12.83-second [changed Time Profiler trace](../profiles/comment-anchors-changed-time.trace) used 1,200 repetitions. Hash lookup, ReviewCard projection, and checksum work remain. The [baseline CPU Counters trace](../profiles/comment-anchors-baseline-counters.trace) and [changed CPU Counters trace](../profiles/comment-anchors-changed-counters.trace) provide hardware evidence for an instruction-throughput workload. The harness reports an 86.96% instruction-rate gap for the final 2,000-item run, but this rate is a calibration proxy rather than a hardware limit.

The macOS Allocations template did not finalize before timeout for either the 15-repetition baseline or a single changed repetition. The benchmark allocator reports 132,446 allocations and 17,251,518 peak bytes for 2,000 items, compared with 128,335 allocations and 15,838,872 peak bytes at baseline. This bounded index cost replaces the repeated scans.

`zig build test --summary all` passes all 700 tests. `zig build bench`, `zig fmt --check src/tui/buffer.zig src/benchmark/comment_anchors.zig src/benchmark/main.zig`, and `git diff --check` pass.
