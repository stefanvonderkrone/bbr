# 12: Grow the search projection ranges without copies

Status: needs-triage
Blocked by: none

## Summary

[Ticket 11](11-build-the-buffer-rows-without-copies.md) removed two copies of the Buffer row array from each Buffer build.
The first copy came from the growth of a list on `std.heap.page_allocator`. On macOS, the page allocator cannot grow a mapping in place, so each growth allocates a new mapping and copies the whole list.
The second copy came from a `dupe` of the finished list into the result allocator.
The class check of ticket 11 found the same two patterns in `SearchProjection` in `src/tui/presentation.zig`.
Nobody has measured their cost.

## Evidence

- `SearchProjection.projectOccurrences` appends each projected range to a list in its `allocator`. `projectRanges` passes its own `allocator` through, and the callers that set `review_ranges` pass `std.heap.page_allocator`. One of them is in `DisclosureBuild.buildFallible`, so each Buffer rebuild with a Review Search Batch grows this list on the page allocator.
- `SearchProjection.project` builds the ranges in a temporary arena and then copies them with `allocator.dupe(frame_mod.ProjectedSourceRange, projected)`. Each rebuild with a Buffer Search Batch runs it.
- `std/heap/PageAllocator.zig` in Zig 0.16.0 cannot grow a mapping in place on macOS. `std/array_list.zig` then allocates and copies.

A broad query can give thousands of ranges. The ranges are smaller than the Buffer rows, so the cost can be small.

## What to decide

Measure first. Use the workload and method of [ticket 05](05-make-a-buffer-rebuild-faster.md), with a Review Search and a Buffer Search that match many lines, and a `sample` profile of the `projection` phase.
If the copies are a measurable part of a rebuild, grow the ranges in the storage that owns the result and return them without a copy, as ticket 11 did for the rows.
If they are not, close this ticket with the numbers.

[Ticket 09](09-make-the-search-projection-cheaper.md) also changes `SearchProjection`. Coordinate with it.

## Comments

### 2026-11-13 filed

Filed from the mistake class check of ticket 11.
