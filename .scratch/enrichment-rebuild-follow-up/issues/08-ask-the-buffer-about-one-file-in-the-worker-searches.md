# 08: Ask the Buffer about one File in the worker searches

Status: needs-triage
Blocked by: none

## Summary

[Ticket 26](../../enrichment-rebuild-cascade/issues/26-check-the-selected-version-availability-without-a-scan-of-all-rows.md) removed a scan of all Buffer rows from the Presentation thread and added `tools/check_row_scans.py`.
The baseline of that check, `tools/row_scan_baseline.txt`, still holds 7 loops in `src/tui/presentation.zig` that call `fileIndexForRow` for each row of a whole row array.
Some of them answer a question about one File and could read only that File's rows:

- `occurrenceVisualRowFor` scans all visual rows to find the first visible row of one occurrence, for a Review destination on the worker. The worker builds a `SearchProjection` just before, which already indexes the occurrence rows.
- `versionNavigationDestination` scans all visual rows of the Buffer to find a destination in one File, on a Selected Version switch.
- `sourceFoldDisclosure` scans all Buffer rows to find the Fold that hides one source Line of one File. It does not call `fileIndexForRow`, so the check does not see it.

`SearchProjection.createWithAllocator` and `SearchProjection.indexDisclosures` must visit every row, but they run a binary search for each row where a walk of the `file_rows` boundaries in order is enough.
Two loops are test helpers outside `test` blocks (`moveToRecoverySource`, `wholeFileGapRow`).

Nobody measured these costs. They run on a worker or on a user action, not on each event. The cost is inferred from the code: O(visual rows × log Files) for each call.

## What the triage decides

- Measure each on the workload of ticket 05 with a Selected Version switch and a Review destination.
- Decide which loops to restrict to a File's rows, and lower the baseline of `tools/check_row_scans.py` with each one.

## Comments

### 2026-11-16 moved for a later PullRequest

The operator moved this ticket out of the enrichment rebuild cascade, where it was ticket 28, so that a later PullRequest owns it.
Ticket numbers in the text above are the numbers of the enrichment rebuild cascade. [The map](../map.md) lists the new numbers.
Take a new baseline at the head of the branch that starts this work.

