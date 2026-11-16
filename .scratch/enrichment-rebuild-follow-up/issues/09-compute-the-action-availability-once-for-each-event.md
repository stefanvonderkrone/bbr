# 09: Compute the action availability once for each event

Status: needs-triage
Blocked by: none

## Summary

`Presentation.projection` in `src/tui/presentation.zig` calls `actionAvailability` each time, and the loop in `src/tui/app.zig` asks for the projection 5 or 6 times for each event, also when the paint revision does not change.
[Ticket 26](../../enrichment-rebuild-cascade/issues/26-check-the-selected-version-availability-without-a-scan-of-all-rows.md) measured 5 calls for a `presentation_done` event and 6 calls for a key or resize event.
After ticket 26, one call costs about 0.001 ms with the cursor on a File header, a Diff Line, or a ReviewCard row, so the repetition costs nothing measurable there.

With a Selection, `actionAvailability` scans the selected rows for a source row, `yankRefusal` scans them again with a File lookup and a card body walk for each row, and in WholeFile scope `wholeFileSourceRefusal` scans them two more times.
A Selection over a large part of the Buffer can make each event cost O(selected rows × log Files) 5 or 6 times. This is inferred from the code and was not measured.

## What the triage decides

- Measure an event with a Selection of the whole first File and of most of the Buffer on the workload of ticket 05.
- If the cost is real, compute the availability once for each Presentation revision, or answer the Selection questions from data that the Selection or the Buffer already has.

## Comments

### 2026-11-16 moved for a later PullRequest

The operator moved this ticket out of the enrichment rebuild cascade, where it was ticket 29, so that a later PullRequest owns it.
Ticket numbers in the text above are the numbers of the enrichment rebuild cascade. [The map](../map.md) lists the new numbers.
Take a new baseline at the head of the branch that starts this work.

