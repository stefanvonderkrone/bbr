# 02: Project Review Search ranges once for each publication batch

Status: needs-triage
Blocked by: none

## Summary

After [ticket 01](01-coalesce-file-enrichment-rebuilds.md), Review Search `e` on PullRequest A acquires every File in about 86 seconds.
The CPU stays at about 100 percent until about 255 seconds.
The Review Search match count grows slowly during that time.

## Evidence

A CPU sample at about 180 seconds shows the Presentation thread, not a worker, in `Published.projectReviewRanges` under `Presentation.dispatch`.
Most samples are in `munmap`, in `ArrayList(usize).append`, and in `PageAllocator.alloc` inside that function.
`search.occurrenceLessThan` also appears.
The match count grew from about 83,000 to about 87,400 in the last 100 seconds.

## Cause (guess)

Each `review_source_scanned` publication for one File projects the ranges of every occurrence again.
With about 87,000 occurrences and 593 Files, the total work grows with the product of the two.
The runner did not confirm this in the code.

## Next step

Triage the cause, measure it, and decide if the Presentation can project only the new File's occurrences or project once for a batch of publications.
