# 25: Measure the page faults of the phases after the visual rows

Status: needs-triage
Blocked by: none

## Summary

[Ticket 21](21-find-why-the-visual-rows-cost-more-without-a-candidate-build.md) found that the phases after the visual rows of every rebuild cause about 11,000 minor faults.
These phases build the File Tree and the search projection.
At 16 KB pages, that is about 170 MB of fresh memory per rebuild.
The growth copy of the visual row array costs about 1.5 µs per fault, so these faults can cost about 15 ms of a 110 ms Unified resize.
Nobody measured this. It is a lead, not a result.

Ticket 21 also found a small, measured saving that this ticket takes over.
`frame.buildVisualRowsWithOptions` appends to an `ArrayList(VisualRow)` in the job arena with no reservation.
Without a candidate build before it, the array outgrows its arena block and copies itself.
A reservation of `rows.len + rows.len / 8` rows took the visual rows of a Unified resize from 26.9 to 24.4 ms and removed 1,640 faults per resize.
The whole resize went from 110.0 to 108.1 ms, which is below the run-to-run range.
Ticket 21 describes the measurement, the reservation, and its acceptance criteria.

## What the triage decides

- Probe `SearchProjection.create` and the File Tree build with the counting allocator and the fault counters of ticket 21. Find which allocations cause the faults, and whether a growth copy or a fresh large allocation causes them.
- If one cause covers both the visual rows and the later phases, design one fix for all of them, for example reservations from known row counts or a reuse of memory across rebuilds.
- Set a measurable target with a baseline. The user wants a significant reduction in the CPU load of a rebuild, so measure process CPU for the resize sequence, not only phase times.
- Decide whether the visual row reservation of ticket 21 lands alone, with the fix of this ticket, or not at all.

Use the workload and the method of ticket 07 and ticket 21.
