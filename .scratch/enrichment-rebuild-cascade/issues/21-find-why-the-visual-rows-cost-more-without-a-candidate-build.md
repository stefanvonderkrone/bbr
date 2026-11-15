# 21: Find why the visual rows cost more without a candidate build

Status: needs-triage
Blocked by: none

## Summary

[Ticket 07](07-build-the-search-candidates-without-a-second-buffer.md) skips the candidate build and the corpus copy of a Unified resize.
The skipped phases had a median of 34.1 ms, but the whole resize lost only 22.2 ms.
In the same runs, the visual row phase of a resize went from 17.2 ms to 26.5 ms.
A disclosure toggle, which never built candidates, has a visual row phase of 26.3 ms before and 26.9 ms after the change.
So the visual row build costs about 9 ms more when no candidate build runs before it in the same job.

A guess, not measured: the candidate build leaves memory in the job arena or in the process that the visual row build then uses without new page faults.
A profile of the visual row phase of a toggle and of a resize at `97c2473` can name the cost.
If the 9 ms is page faults of a new arena block, a reserved or reused block for the visual rows can save it on every rebuild kind.

## Evidence

The workload and method are the ones of ticket 07. Three runs per side, 24 resizes and 24 toggles per side.
