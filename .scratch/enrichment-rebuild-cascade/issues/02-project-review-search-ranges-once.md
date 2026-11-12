# 02: Project Review Search ranges once for each publication batch

Status: resolved
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

- [x] A test publishes the source scans of several Files one by one. After each publication, the ranges, the order of the occurrences, the selection, and the results are the same as a full projection of the combined state.
- [x] A test changes the visual rows between two publications, for example with a Layout switch or `o`. The ranges after the next publication match the new visual rows.
- [x] A test shows that a publication does not walk all visual rows when the visual rows did not change.
  It can count index builds or use a seam that the implementation exposes.
- [x] Allocation failure tests for the new path keep the previous Review Search state, as `reviewSourcePublicationFailed` does today.
- [x] Before the change, the runner measures a baseline at commit `93c4600`, with the same build mode and the same steps.
  The steps: a ReleaseFast build, PullRequest A at 160 × 80 in tmux with a separate `XDG_STATE_HOME`, `g f`, then `e`, then wait until the CPU is idle.
  The measures: the total CPU time of the bbr process from `e` until idle (`ps -o time=` before and after), the time when File Enrichment ends, and the time when the CPU becomes idle.
- [x] After the change, the same steps use at most half of the baseline CPU time.
- [x] After the change, the CPU becomes idle within 15 seconds after File Enrichment ends.
- [x] The completion records the baseline, the result, and the reduction in percent.
- [x] `zig build test` passes.

## Completion

Commit `3df43d51` on branch `enrichment-rebuild-cascade` changes `src/tui/presentation.zig` and `src/tui/search.zig`.

- `acceptReviewSourceScanned` ranks only the new part. `search.mergeRanked` merges it into the ranked occurrences. An equal earlier occurrence comes first, so the order is the order of the stable `search.rank` on the combined array. `std.mem.sort` is a stable block sort (`std/mem.zig` lines 612 to 619 in Zig 0.16.0).
- `Published.mergeReviewRanges` projects only the new part through `published.search_projection`. The Frame builds that index once for each visual row revision. The function remaps the occurrence indexes of the existing ranges and merges the two sorted range lists.
- The existing ranges always belong to the current visual rows. Every rebuild commit projects them again, and a rebuild with a stale Review Search snapshot retries.
- If the Review Search has no ranges, the publication uses the full projection, as before.

The selection, the active range, the results, and the allocation failure behavior stay the same.

### Tests

New Presentation tests cover the criteria:

- "each Review Search source publication matches a full projection of the combined state": 12 Files, a Draft, and selection moves. After each publication, the occurrence order, the selection, the ranges, and the results match a full rank and a full projection.
- "a Review Search source publication after a resize projects the new visual rows": a resize changes the visual rows between two publications. A Layout switch does nothing while Review Search is open, so the test uses a resize.
- "a Review Search source publication does not walk the visual rows": each publication after the first runs with empty visual rows and Buffer rows. The ranges still match a full projection. This test fails with the full projection path.
- "an allocation failure in a Review Search source publication keeps the previous state": a sweep fails each `Presentation` allocation in a publication. Each failure keeps the occurrences, the ranges, the results, the selection, and the Frame revision, and reports `out_of_memory`. The sweep does not reach the `page_allocator` allocations.

### Checks

- `zig build test`: pass.
- `zig fmt --check build.zig src tests`: pass.
- `python3 tools/check_agent_docs.py`: pass.

### Live check

The runner used ReleaseFast builds of `93c4600` and `3df43d51`, tmux at 160 × 80, a separate `XDG_STATE_HOME`, `g f`, then the query `e`. The CPU time is `ps -o time=` from the query until idle. The runner polled every 5 seconds. File Enrichment ends when the candidate count stops. The CPU is idle when `ps -o pcpu=` falls under 3 percent.

Bitbucket rate-limited the blob requests after a few runs. A rate-limited run acquires fewer Files, so its CPU time is not comparable. The table keeps only the runs whose candidate count was near the full count.

| PullRequest A | CPU time | File Enrichment ends | CPU idle | Matches · candidates |
| --- | --- | --- | --- | --- |
| Baseline `93c4600` | 266.7 s | about 91 s | about 268 s | 86,320 · 137,335 |
| Result, run 1 | 75.1 s | about 76 s | about 76 s | 84,741 · 134,883 |
| Result, run 2 | 72.3 s | about 80 s | about 80 s | 84,651 · 134,707 |

The reduction is 72 percent and 73 percent. The CPU becomes idle within 5 seconds after File Enrichment ends.
The result runs acquired about 2 percent fewer candidates than the baseline run. The runner thinks that rate limiting caused this, because a run earlier in the day reached 139,058 candidates.

A local Review of this repository against an older commit has 416 Files and no network requests, so it has a fixed workload. The runner ran it with `bbr local` and the same steps, twice for each build.

| Local Review | CPU time | File Enrichment ends | CPU idle | Matches · candidates |
| --- | --- | --- | --- | --- |
| Baseline `93c4600` | 296.7 s, 294.5 s | about 51 s, 81 s | about 293 s, 298 s | 163,460 · 238,250 |
| Result | 35.8 s, 35.8 s | about 20 s | about 30 s | 163,460 · 238,250 |

The reduction is 88 percent, with the same matches and candidates. The CPU becomes idle within 10 seconds after File Enrichment ends.

### Review

The two-axis code review found no violation of a documented standard and no correctness bug. The runner renamed the scratch allocator parameter of `mergeReviewRanges` and documented that the result belongs to `page_allocator`. The runner also removed a duplicated command loop in the tests.

A publication still copies the occurrence, range, and result arrays, so its cost grows with all occurrences. That copy is linear and cheap next to the old index build and sort.

## Comments

### 2026-11-12 triage

The runner triaged the ticket at the operator's request and set it to `ready-for-agent`.
The triage read the code and confirmed the cause that the ticket guessed.
The same publication path exists on `main`.

### 2026-11-12 open points

- `selectReviewSearch` and `acceptReviewSearchScanned` still call the full projection, which builds the source row index over all visual rows. Each selection move in a large Review Search pays this cost once.
- A view build that waits while source scans run becomes stale at each publication, because its Review Search snapshot is older. So a resize during source scanning waits until the scans end.
