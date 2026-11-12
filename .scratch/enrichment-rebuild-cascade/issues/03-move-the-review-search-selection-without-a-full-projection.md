# 03: Move the Review Search selection without a full projection

Status: needs-triage
Blocked by: none

## Summary

[Ticket 02](02-project-review-search-ranges-once.md) left one full projection on a frequent path.
Each selection move in Review Search projects every occurrence again over all visual rows.
On a large PullRequest, each `j`, `k`, or arrow key in the results list pays that cost on the Presentation thread.

## Cause

All paths are in `src/tui/presentation.zig`.

`selectReviewSearch` calls `projectReviewRanges` with the new selected index.
That function calls `projectBufferSearchRangesFor`, which builds a `SourceRowKey` index over every visual row and then projects every occurrence.
On PullRequest A, that is about 111,700 visual rows and about 87,000 occurrences for one key press.

The projection does not change with the selection, except for one field.
`frame.ProjectedSourceRange` holds `active` and `occurrence_index`.
A selection move only clears `active` on the ranges of the old selection and sets it on the ranges of the new selection.

`acceptReviewSearchScanned`, the first result of a query, also calls the full projection.
That call is once for each query, so this ticket does not require a change there.

## What to build

A selection move updates the `active` flag of the ranges of the old and the new selection.
It does not project the occurrences again, and it does not walk the visual rows.
When the ranges are absent or do not belong to the current occurrences, the move falls back to the full projection.

## Acceptance criteria

- [ ] A test moves the selection through several occurrences, in source and in ReviewBody locations. After each move, the ranges are the same as a full projection with the new selected index.
- [ ] A test shows that a selection move does not walk the visual rows, in the same way as the test "a Review Search source publication does not walk the visual rows" of ticket 02.
- [ ] An allocation failure on the new path keeps the previous selection and ranges, as `selectReviewSearch` does today.
- [ ] The live check measures the CPU time of 50 `j` presses in the Review Search results for `e` on PullRequest A at 160 × 80, after all Files are acquired.
  It measures the same steps at the commit before the change.
  The completion records both CPU times and the reduction in percent.
- [ ] `zig build test` passes.

## Comments
