# 03: Move the Review Search selection without a full projection

Status: resolved
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

- [x] A test moves the selection through several occurrences, in source and in ReviewBody locations. It uses `moveReviewSearch`, `scrollReviewSearch`, and a press in the results list. After each move, the ranges are the same as a full projection with the new selected index.
- [x] A test shows that a selection move does not walk the visual rows, in the same way as the test "a Review Search source publication does not walk the visual rows" of ticket 02.
- [x] A test shows that a selection move with ranges present makes no allocation, for example with a failing allocator.
- [x] A test covers the fallback when the ranges are absent.
- [x] The live check repeats the measurement of this ticket with the same workload and steps, before and after the change.
  50 `Down` presses use at most 10 percent of the baseline CPU time, at most 3.8 seconds.
  The CPU is idle within 2 seconds after the last press.
  The completion records both CPU times and the reduction in percent.
- [x] `zig build test` passes.

## Comments

### 2026-11-12 triage

The runner triaged the ticket at the operator's request and set it to `ready-for-agent`.
The triage measured the cost, confirmed the cause in the code, and set a CPU target.
The live check uses `bbr local` in this repository, because a local Review has a fixed workload and needs no network or Bitbucket rate limit.

The first result of a query calls the same projection with the page allocator.
On the same workload, it can cost about 0.77 seconds of Presentation time for each query generation.
The triage did not measure it.
A follow-up ticket can change `projectReviewRanges` to the retained `search_projection`, or give the row index an arena.

### 2026-11-12 open point

A disclosure build that starts before a selection move can publish its Review Search ranges with the selection of its start.
The admissions in `src/tui/presentation.zig` that take `job.review_ranges` do not mark the active ranges again.
This behavior existed before this ticket. This ticket did not change it.

## Completion

Commits `e995fc96` and `cc64438b`.

### Change

- A selection move with ranges present calls `markActiveSearchRanges` and keeps the same ranges array.
  It does not project, does not walk the visual rows, and does not allocate.
- Without ranges, a move projects through the retained `SearchProjection` with the new `SearchProjection.projectRanges`.
- `acceptReviewSearchScanned`, the merge fallback, the disclosure rebuild, and the Buffer Search benchmark also use the retained `SearchProjection`.
- `Published.projectBufferSearchRangesFor` and `Published.projectBufferSearchRanges` are a compile error outside a test build.
  The tests use them as the independent oracle.
  The old `projectReviewRanges` body of commit `48e6abc` fails `zig build` with this error.
- The rules table in `AGENTS.md` has a row for the retained projection and its enforcement.
- The fixture `openTestReviewSourceSearch` has an emphasized ReviewBody match, so one occurrence has two ranges.

### Tests

- "Review Search selection moves keep source and ReviewBody ranges active in place" uses `moveReviewSearch`, `scrollReviewSearch`, and a press in the results list.
- "a Review Search selection move does not walk the visual rows".
- "a Review Search selection move allocates nothing and keeps its ranges array".
  The Presentation allocator records no allocation, and the ranges array keeps its pointer.
- "a Review Search selection move projects absent ranges".
- The M21 disclosure worker test now compares complete ranges with the oracle.

### Live check

ReleaseFast builds, the workload and the steps of the measurement above, one press each 0.2 seconds.
The baseline is commit `48e6abc`. Runs alternated between the baseline and the change.

| Run | CPU time of 50 `Down` presses | Busy time after the last press |
| --- | --- | --- |
| Baseline 1 | 37.95 seconds | 27.6 seconds |
| Baseline 2 | 36.09 seconds | 25.6 seconds |
| Change 1 | 1.97 seconds | 0.02 seconds |
| Change 2 | 1.97 seconds | 0.02 seconds |
| Change 3 | 1.94 seconds | 0.02 seconds |

The CPU time went from 37.0 seconds (median of 2) to 1.97 seconds (median of 3), a reduction of 94.7 percent.
Each run ended at selection 15645 of 160,576 matches, 50 moves after the start.
The CPU time from the query until idle did not change measurably: 43.1 and 43.3 seconds before, 41.9 to 42.9 seconds after.

### Checks

- `zig build test --summary all`: exit code 0, 1623 of 1623 tests passed.
- `zig fmt --check build.zig src tests`: exit code 0.
- `python3 tools/check_agent_docs.py`: pass.

### Review

The Standards and Spec reviews found no hard violation.
The fixes after the review: one constant for the compile error message, a `projectOccurrences` call in `mergeReviewRanges`, a selection check before the backward scroll, and a correct claim in the rules row.
The open point above remains.

