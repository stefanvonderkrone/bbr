# Fix the missing cache build of the Buffer Search benchmark

Status: needs-triage
Blocked by: none

## Problem

`zig build bench-buffer-search` stops with `error: MissingCacheBuild`.
The error comes from `benchmarkCacheFrames` in `src/tui/presentation.zig`, at `presentation.takeCommand() orelse return error.MissingCacheBuild`.
The benchmark expects a `build_buffer_disclosure` command after `ensure_focused_enrichment`, `finishSearchLease`, or `releaseReviewSearchHolds`, but no command is queued.

The failure is older than the stack of PRs 41 to 46.
On 2026-11-22, the benchmark failed in the same way on `main` before PR 41 merged, and on `doc-symbol-check`.
No commit of the stack changed this benchmark function, except for the `presentation` pointer fix in `b735a10e`.

`benchmarkCacheFrames` calls `finishSearchLease` and `releaseReviewSearchHolds` directly, outside `dispatch`.
Since PR 46, `showError` panics outside an event, and `clearError` panics outside an event while an error shows.
A fix must keep these calls inside an event or inside `withErrorOrigin`.

## Proposal

- Find the commit that made the benchmark stop queuing a cache build. A `git bisect` with `zig build bench-buffer-search` is the cheapest way.
- Decide whether the production code or the benchmark fixture is wrong. Fix that side.

## Acceptance criteria

- [ ] `zig build bench-buffer-search` exits with 0.
- [ ] The ticket records the commit that broke the benchmark and whether the cause was the code or the fixture.
- [ ] `zig build test` passes.
