# Build repeatable performance profiles

Type: task
Blocked by: 03

## Question

How will each remaining P0 improvement target expose a stage-isolated ReleaseFast workload for stable CPU and memory profiles?

Add the minimum benchmark coverage and repeat mode for macOS `xctrace`. Capture baseline Time Profiler or CPU Profiler data and Allocations data. Record hot stacks and allocation or VM call sites. Record hardware counters where the host supports them. Preserve output checksums and portable benchmark code. Distinguish hardware evidence from the harness calibration proxies.
