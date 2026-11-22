# Compile every benchmark in zig build test

Status: needs-triage
Blocked by: none

## Problem

`zig build test` does not compile the benchmark executables.
A change can break a benchmark, and the suite and CI still pass.

This happened twice:

- A compile error in `src/benchmark_file_cache.zig` passed the suite. Commit `4b6abe50` records this case.
- The origin codemod of PR 46 wrote `&presentation` in benchmark functions that take `presentation` as a pointer. `zig build bench-buffer-search` did not compile, and `zig build test` passed. Commit `b735a10e` fixed it.

Commits `4b6abe50` ("build: compile every benchmark in zig build test") and `68c4d678` ("build: add every benchmark through addBenchmark") fix this class.
Both are only on the branch `m28-full-review-file-cache-evaluation`, which is 60 commits ahead of `main` and not merged.

## Proposal

- Bring `4b6abe50` and `68c4d678` to `main` on their own, without the rest of the branch.
- `addBenchmark` makes each benchmark executable a dependency of `zig build test`, so a new benchmark cannot skip the compile step.
- Break one benchmark on purpose and check that `zig build test` fails.

## Acceptance criteria

- [ ] `zig build test` compiles every benchmark executable on `main`.
- [ ] A compile error in any benchmark root makes `zig build test` fail.
- [ ] `docs/rules/build-and-checks.md` has a rule section with an Enforcement paragraph for this check.
- [ ] `zig build test` passes.
