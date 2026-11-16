# 30: Find what bounds the remaining search projection cost

Status: needs-triage
Blocked by: 09

## Summary

[Ticket 09](09-make-the-search-projection-cheaper.md) made `SearchProjection.create` about 30 percent cheaper in Unified and 24 percent cheaper in SideBySide.
The phase still takes about 28 ms of a Unified resize and 38.5 ms of a switch to SideBySide on the workload of ticket 05.
The limiter that ticket 09 names is inferred, not profiled: about 4,800 faults of fresh projection memory, the hashing of about 370,000 `source_rows` keys and the `spans` keys, and the two passes of `KeyLists.build` over the rows.

## What to find

- A `sample` profile of Unified resizes and SideBySide switches at the head of the branch, with the share of each part of the phase.
- Whether the remaining faults come from the `KeyLists` maps, the entry arrays, or the scratch key numbers that stay in the projection arena.
- Whether a cheaper hash or a smaller key, such as a `u32` File index, changes the phase by more than the run-to-run range.

Ticket 12 (projected search ranges) and ticket 27 (other lists that grow from empty) are separate.
