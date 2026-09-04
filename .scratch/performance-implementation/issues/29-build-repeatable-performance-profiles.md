# Build repeatable performance profiles

Type: task
Status: claimed
Blocked by: 03

## Question

How will each remaining P0 improvement target expose a stage-isolated ReleaseFast workload for stable CPU and memory profiles?

Add the minimum benchmark coverage and repeat mode for macOS `xctrace`. Capture baseline Time Profiler or CPU Profiler data and Allocations data. Record hot stacks and allocation or VM call sites. Record hardware counters where the host supports them. Preserve output checksums and portable benchmark code. Distinguish hardware evidence from the harness calibration proxies.

## Comments

The benchmark now accepts `--repeat <count> <benchmark>`. Each repetition uses a fresh arena and checks the output checksum. Time Profiler and CPU Counters captured valid 8,000-repetition traces for `intraline_500_parts` and `buffer_projection_300_files_50000_lines` under `profiles/`.

The intraline Time Profiler trace runs for 11.73 seconds. Its hot stacks are `diff.intraline.commonTable`, `mem.eqlBytes`, and `diff.intraline.tokenize`. Allocation and VM samples in the same trace reach the intraline arena through `heap.c_allocator_impl.alloc`, `heap.c_allocator_impl.resize`, and `mem.Allocator.rawFree`.

The Buffer Time Profiler trace runs for more than 10 seconds. Its hot stacks include `buffer.Weave.emitUnifiedHunk`, `buffer.Weave.weaveInline`, `buffer.computeEmphasis`, `buffer.decoratedLine`, Row list growth, and arena allocation. `_platform_memset` appears below `buffer.fileTallies`.

CPU Counters completed for both workloads on the Apple M5 Pro host. These traces are hardware evidence. The `ceiling_rate` and `gap_percent` fields from `zig build bench` remain synthetic calibration proxies.

Allocations cannot attach to `bbr-bench` while macOS Developer Mode is disabled. `DevToolsSecurity -status` reports `Developer mode is currently disabled.` This ticket remains claimed until an Allocations trace completes.
