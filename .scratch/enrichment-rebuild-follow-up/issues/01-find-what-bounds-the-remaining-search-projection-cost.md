# 01: Find what bounds the remaining search projection cost

Status: needs-triage
Blocked by: none

## Summary

[Ticket 09 of the enrichment rebuild cascade](../../enrichment-rebuild-cascade/issues/09-make-the-search-projection-cheaper.md) made `SearchProjection.create` about 30 percent cheaper in Unified and 24 percent cheaper in SideBySide.
The phase still takes about 28 ms of a Unified resize and 38.5 ms of a switch to SideBySide on the workload of [ticket 05](../../enrichment-rebuild-cascade/issues/05-make-a-buffer-rebuild-faster.md).
The limiter that ticket 09 names is inferred, not profiled: about 4,800 faults of fresh projection memory, the hashing of about 370,000 `source_rows` keys and the `spans` keys, and the two passes of `KeyLists.build` over the rows.

## What to find

- A `sample` profile of Unified resizes and SideBySide switches at the head of the branch, with the share of each part of the phase.
- Whether the remaining faults come from the `KeyLists` maps, the entry arrays, or the scratch key numbers that stay in the projection arena.
- Whether a cheaper hash or a smaller key, such as a `u32` File index, changes the phase by more than the run-to-run range.

Ticket 12 (projected search ranges) and ticket 27 (other lists that grow from empty) of the enrichment rebuild cascade are separate.

## Comments

### 2026-11-16 moved for a later PullRequest

The operator moved this ticket out of the enrichment rebuild cascade, where it was ticket 30, so that a later PullRequest owns it.
Its blocker, ticket 09 of the enrichment rebuild cascade, is resolved at `c200731`.
Take a new baseline at the head of the branch that starts this work.

