# Build repeatable performance profiles

Type: task
Status: resolved
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

Developer Mode was enabled. Allocations then required an ad-hoc `com.apple.security.get-task-allow` entitlement on the generated `zig-out/bin/bbr-bench` binary. Both 8,000-repetition workloads completed after that temporary signing step.

## Answer

Use `bbr-bench --repeat <count> <benchmark>` to profile one stage. The command builds each fixture once, runs the selected stage with a fresh arena for each repetition, rejects checksum changes, and reports the final checksum. Normal `zig build bench` measurements are unchanged.

Each P0 ticket must add its named stage benchmark before it changes production code. The ticket must use repeat mode to capture the baseline and the changed stage. A repeat count must keep the stage active for at least 10 seconds under Time Profiler or CPU Profiler. The same workload must run under Allocations and CPU Counters when the host supports them.

The baseline assets are in `../profiles/`: Time Profiler, Allocations, and CPU Counters traces for `intraline_500_parts` and `buffer_projection_300_files_50000_lines`. These workloads cover the current Diff intraline and Buffer projection stages. The remaining P0 tickets own their narrower Highlighting, navigation, Span, Comment anchor, cell-width, and paint workloads.

The current host is an Apple M5 Pro running macOS arm64 with Zig 0.16.0 and the `apple_m1` target. The Time Profiler traces identify the hot stacks recorded above. The Allocations traces capture heap and VM events for the same stages. CPU Counters provides the hardware evidence. Harness ceiling rates remain calibration proxies and cannot classify a hardware ceiling.

All benchmark checksums stayed stable. `zig build test --summary all` passes all 697 tests. `zig fmt --check build.zig src/benchmark` and `git diff --check` pass.
