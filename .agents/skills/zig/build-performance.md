# Build and performance corrections

## Native dependency builds

Pin exact dependency commits and hashes in `build.zig.zon`.
Set `minimum_zig_version`. libvaxis dependencies can require `b.lazyDependency`.

For Linux C dependency failures, check feature macros and platform-specific source files in `build.zig`.
Keep `-D_DEFAULT_SOURCE` on the tree-sitter runtime compiled with `-std=c11`.
Keep Linux ELF, vDSO, address-probe, and futex implementations in the Abseil source list.
Commit `0164ee0` records these requirements.
After dependency changes, run the native Linux RE2 and UserGrammar CI steps.
A macOS build does not prove Linux behavior.

Zig 0.16 cannot build bundled libc++ with a macOS 26 deployment minimum.
Keep bbr's native deployment minimum at macOS 15 on newer hosts.
Add the active SDK framework and library paths for that explicit target.
Current CoreFoundation headers also require `-Wno-elaborated-enum-base` for Zig's C++ compiler.
Remove these workarounds after a Zig upgrade passes the full test step.

## Measurements

Use `std.Io.Clock.awake` for benchmark duration.
Take the start with `.now(io)` and measure with `start.untilNow(io, .awake).toNanoseconds()`.
Build fixtures before timing and reject semantic checksum drift.
Pass the result or checksum to `std.mem.doNotOptimizeAway`.

Count allocations at one allocator layer.
A counter inside an arena measures workload allocation calls.
A counter outside an arena measures backing allocations.
Record `queryCapacity()` separately for retained memory.

## Bounded algorithms

Treat `std.simd.suggestVectorLength(T)` as optional and target-dependent.
Use the suggested length when present, then handle the scalar tail.
Keep scalar reference tests for short lengths, unaligned starts, controls, and non-ASCII text.
SIMD helps early exits. It does not remove dependencies in an LCS algorithm.

Bound quadratic work before allocating its table.
Use saturating `*|` and `+|` for work estimates.
Preserve exact results below a measured limit and use a deterministic fallback above it.
bbr applies this rule to intraline LCS and SideBySide Line matching.
