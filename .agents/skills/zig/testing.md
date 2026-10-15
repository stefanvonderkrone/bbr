# Test corrections

## Test discovery

Tests run only when reachable through test-block import chains from the test root.
Calling a function in another file compiles that file but does not run its test blocks.
Connect new test files through `test { _ = @import("child.zig"); }` chains.
Confirm that the relevant count increases with `zig build test --summary all`.

A source file can belong to only one module.
From an executable module, reach library-owned helpers through the library API, such as `bbr.http.Canned`.
Importing a library-owned file by relative path can produce a duplicate-module error.

## Hermetic fixtures

Tests receive neither `Init` nor `Io` from the test runner.
Use fakes and embedded fixtures instead of process environment reads.
Put Credential and network checks in explicit executable steps that read `Init.environ_map` in `main`.

`std.testing.allocator` detects leaks per test.
Pair owned allocations with their cleanup and test domain behavior through the existing seams.

## Pagination stalls

`FakeHttpClient` repeats the same body unless given a scripted response sequence.
A repeated page with a `next` link can keep a pagination client in an infinite loop.
Use a response sequence whose last page omits `next`, or use a single-page fixture.

When a test stalls, distinguish the running test binary from the compiler.
Run the test executable with a bounded process timeout to expose the last test name.
Use the configured build dependencies when invoking a test root directly.
Stop the relevant process rather than killing every live Zig build.
A forced global kill can orphan the cache manager and block later builds.
