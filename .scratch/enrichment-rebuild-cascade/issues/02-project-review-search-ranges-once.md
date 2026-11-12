# 02: Project Review Search ranges once for each publication batch

Status: ready-for-agent
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

## Cause

The triage confirmed the cause in `src/tui/presentation.zig` on 2026-11-12.
`main` has the same code, so ticket 01 did not add it. Ticket 01 only made it visible.

`acceptReviewSourceScanned` runs on the Presentation thread once for each File whose source scan completes.
For each File, it does this work over the whole Review Search state:

1. It copies the old occurrences and the new part into a new array.
2. `search.rank` sorts the combined array again.
3. `projectReviewRanges` calls `projectBufferSearchRangesFor`.
   That function builds a `SourceRowKey` hash map over every visual row, about 111,700 on PullRequest A.
   Then it projects every occurrence, not only the new ones.
4. It allocates a new `ReviewSearchResult` array for every occurrence.

So the cost of one publication grows with the visual rows plus all occurrences, and the total grows with the number of Files times that.
On PullRequest A, that is 593 publications over about 87,000 occurrences.
The work blocks the Presentation thread, so input also waits.

## Goal

The goal is a significant reduction of the CPU load of a Review Search on a large PullRequest.
A change that is correct but does not reduce the measured CPU time does not resolve this ticket.

## What to build

The cost of one source scan publication grows with the occurrences of the new File, not with all visual rows and all occurrences.

- Build the source row index once for each visual row revision, and reuse it for later publications.
  Build it again only when the visual rows change.
- Project only the occurrences of the new part, and merge the result into the sorted ranges.
- Merge the new part into the ranked occurrences instead of sorting the whole array again, if the rank order allows a merge.
- Keep the selection, the active range, and the results that a Review Search shows today.

Another design that meets the criteria is also acceptable, for example one projection for each batch of publications.

## Acceptance criteria

- [ ] A test publishes the source scans of several Files one by one. After each publication, the ranges, the order of the occurrences, the selection, and the results are the same as a full projection of the combined state.
- [ ] A test changes the visual rows between two publications, for example with a Layout switch or `o`. The ranges after the next publication match the new visual rows.
- [ ] A test shows that a publication does not walk all visual rows when the visual rows did not change.
  It can count index builds or use a seam that the implementation exposes.
- [ ] Allocation failure tests for the new path keep the previous Review Search state, as `reviewSourcePublicationFailed` does today.
- [ ] Before the change, the runner measures a baseline at commit `93c4600`, with the same build mode and the same steps.
  The steps: a ReleaseFast build, PullRequest A at 160 × 80 in tmux with a separate `XDG_STATE_HOME`, `g f`, then `e`, then wait until the CPU is idle.
  The measures: the total CPU time of the bbr process from `e` until idle (`ps -o time=` before and after), the time when File Enrichment ends, and the time when the CPU becomes idle.
- [ ] After the change, the same steps use at most half of the baseline CPU time.
- [ ] After the change, the CPU becomes idle within 15 seconds after File Enrichment ends.
- [ ] The completion records the baseline, the result, and the reduction in percent.
- [ ] `zig build test` passes.

## Comments

### 2026-11-12 triage

The runner triaged the ticket at the operator's request and set it to `ready-for-agent`.
The triage read the code and confirmed the cause that the ticket guessed.
The same publication path exists on `main`.
