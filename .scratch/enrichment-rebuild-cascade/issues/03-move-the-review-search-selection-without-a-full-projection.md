# 03: Move the Review Search selection without a full projection

Status: ready-for-agent
Blocked by: none

## Summary

[Ticket 02](02-project-review-search-ranges-once.md) left one full projection on a frequent path.
Each selection move in Review Search projects every occurrence again over all visual rows.
On a large PullRequest, each `j`, `k`, or arrow key in the results list pays that cost on the Presentation thread.

## Measurement

The triage measured the cost on 2026-11-12 at commit `1836261`, in a ReleaseFast build.
The workload is fixed and needs no network:

- `bbr local fb701b1 1836261` in this repository, at 160 × 80 in tmux with a separate `XDG_STATE_HOME`.
- 479 Files and 187,827 Buffer rows.
- Review Search `e`: 160,576 matches and 234,723 candidates after all Files are scanned.

| Measure | Value |
| --- | --- |
| CPU time of 50 `Down` presses, one press each 0.2 seconds | 38.4 seconds |
| CPU time of one selection move | about 0.77 seconds |
| Time from the first press until the CPU is idle | 40.6 seconds for 10 seconds of presses |

The key presses queue up, so the results list lags behind the keyboard by many seconds.

A CPU sample during the moves puts almost all of `selectReviewSearch` in `projectReviewRanges`:

- About 48 percent of the samples are in `munmap`, and about 10 percent are in `mmap`.
- About 20 percent are in `ArrayList(usize).append` for the source row index.
- The rest is the sort and the projection.

## Cause

All paths are in `src/tui/presentation.zig`.

`selectReviewSearch` calls `projectReviewRanges` with the new selected index.
That function calls `projectBufferSearchRangesFor` with `std.heap.page_allocator`.
`projectBufferSearchRangesFor` builds a `SourceRowKey` index over every visual row.
Each key holds its own `ArrayList(usize)`, so with the page allocator each source line maps and unmaps its own memory pages.
Then it projects every occurrence and sorts all ranges.

The projection does not change with the selection, except for one field:

- `frame.ProjectedSourceRange` holds `active` and `occurrence_index`. Every review range has an `occurrence_index`.
- `searchRangeLess` does not read `active`, so a change of `active` keeps the sort order.
- `DisclosureBuild` already sets `active` in place after a projection (`for (self.review_ranges.?) |*range| range.active = ...`).

So a selection move only has to clear `active` on the ranges of the old selection and set it on the ranges of the new selection.
`selectReviewSearch` already frees the old ranges at this point, so no other owner reads them while the Presentation changes them.

## What to build

A selection move updates the `active` flag of the ranges of the old and the new selection.
It does not project the occurrences again, does not walk the visual rows, and does not allocate.
When the ranges are absent, the move falls back to the full projection.

`selectReviewSearch` serves `moveReviewSearch`, `scrollReviewSearch`, and a mouse press in the results list. All three paths get the fast update.

`acceptReviewSearchScanned`, the first result of each query generation, also calls `projectReviewRanges`.
It is out of scope for this ticket. See the comment below.

## Acceptance criteria

- [ ] A test moves the selection through several occurrences, in source and in ReviewBody locations. It uses `moveReviewSearch`, `scrollReviewSearch`, and a press in the results list. After each move, the ranges are the same as a full projection with the new selected index.
- [ ] A test shows that a selection move does not walk the visual rows, in the same way as the test "a Review Search source publication does not walk the visual rows" of ticket 02.
- [ ] A test shows that a selection move with ranges present makes no allocation, for example with a failing allocator.
- [ ] A test covers the fallback when the ranges are absent.
- [ ] The live check repeats the measurement of this ticket with the same workload and steps, before and after the change.
  50 `Down` presses use at most 10 percent of the baseline CPU time, at most 3.8 seconds.
  The CPU is idle within 2 seconds after the last press.
  The completion records both CPU times and the reduction in percent.
- [ ] `zig build test` passes.

## Comments

### 2026-11-12 triage

The runner triaged the ticket at the operator's request and set it to `ready-for-agent`.
The triage measured the cost, confirmed the cause in the code, and set a CPU target.
The live check uses `bbr local` in this repository, because a local Review has a fixed workload and needs no network or Bitbucket rate limit.

The first result of a query calls the same projection with the page allocator.
On the same workload, it can cost about 0.77 seconds of Presentation time for each query generation.
The triage did not measure it.
A follow-up ticket can change `projectReviewRanges` to the retained `search_projection`, or give the row index an arena.

