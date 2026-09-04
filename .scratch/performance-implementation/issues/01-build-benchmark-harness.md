# Build the benchmark harness

Type: task
Status: resolved
Blocked by: none

## Question

How will `zig build bench` provide deterministic ReleaseFast measurements for the stages, fixtures, allocation data, retained memory, and output checksums required by Action 0 in `PERFORMANCE.md`? How will each benchmark identify its instruction-throughput or memory-bandwidth ceiling and report the measured gap?

## Answer

`zig build bench` now builds and runs the ReleaseFast `bbr-bench` executable. A normal release build also installs `zig-out/bin/bbr-bench` for branch-to-branch `hyperfine` comparisons. For example, `zig build --release=safe` produces a ReleaseSafe benchmark binary that runs through `./zig-out/bin/bbr-bench`. An optional benchmark name runs one stage.

The harness generates all fixtures before timing. It runs two warmups and 15 measured samples per stage. Each result reports median and p95 time, allocation count, peak requested bytes, retained arena capacity, and a stable semantic output checksum. The harness rejects a run when its checksum changes between samples.

The harness measures an instruction-throughput ceiling and a memory-bandwidth ceiling on each host. Every benchmark selects one ceiling and reports its measured rate and gap. The first benchmark files cover Diff parsing, Buffer projection, and intraline diff. They use the 300-File and 50,000-Line Diff fixture plus a deterministic 500-part minified Line pair.

ReleaseFast baseline on an Apple M5 Pro host with Zig's `apple_m1` compilation target, macOS arm64, and Zig 0.16.0:

| Stage | Median | p95 | Allocations | Peak bytes | Retained bytes | Checksum | Ceiling gap |
|---|---:|---:|---:|---:|---:|---|---:|
| Diff parse | 397,834 ns | 439,875 ns | 1,226 | 2,074,228 | 3,178,874 | `bce79ba680bfd196` | 91.32% memory bandwidth |
| Buffer projection | 989,250 ns | 1,125,833 ns | 100,325 | 15,331,064 | 59,763,880 | `73589213e9cfeb5e` | 96.51% memory bandwidth |
| Intraline diff | 1,345,542 ns | 1,407,333 ns | 11 | 8,053,392 | 12,149,508 | `1ea2acca84a12f65` | 79.58% instruction throughput |

`zig build test --summary all` passes all 695 tests. `zig fmt --check build.zig src/benchmark` and `git diff --check` also pass.
