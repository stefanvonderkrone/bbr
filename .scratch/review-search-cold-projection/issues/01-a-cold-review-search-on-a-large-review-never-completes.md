# A cold Review Search on a large Review never completes

Status: needs-triage
Blocked by: none

## Summary

A cold Review Search on the largest M28 benchmark PullRequest did not complete in 2 hours.
The process used one CPU core at 100% for the whole time.
Bitbucket and the rate limit were not the cause.
CPU samples show repeated work in `SearchProjection.create` and the Buffer and visual row builders.

The M28 cache decision does not change.
[ADR-0016](../../../docs/adr/0016-file-cache-stays-a-session-only-lru.md) records that decision.
This ticket is about CPU work in Review Search, not about the File cache.

## Evidence

The operator's agent ran M28 scenario S4 on 2026-11-02 from 19:28 to 21:32 CET.
S4 restarts the Presentation and the HTTP client, loads the Session, and opens Review Search with the query `return`.

- Command: `bbr-file-cache-bench remote pr-webapp <PullRequest A> --scenarios s4 --run-label coldsearch --network-label home-office-vpn-wired`.
- bbr version: `2026.11.2-0+ge5d60b6f8b3d`.
- Options: the default budget of 256 MiB and the default dwell time of 1,000 ms.
- The S1 footprint run of the same PullRequest needs 663 File requests for a cold full fetch.

Timeline of the request window:

| Time after start | Requests | Request rate |
| --- | ---: | ---: |
| 0 to 4 min | about 200 | about 50 per min |
| 29 to 30 min | 404 to 421 | about 17 per min |
| 30 to 59 min | 421 to 549 | about 4 per min |
| 59 to 84 min | 549 to 637 | about 3.5 per min |
| 98 to 123 min | 681 to 681 | 0 |

- The request window never forced a wait. The request rate fell while the CPU stayed at 100%.
- After request 681, no request was sent for at least 25 minutes. The process still used 99.6% CPU.
- No result line appeared. The operator stopped the process after 2 h 03 min.
- 8 `HttpConnectionClosing` retries happened. Each one recovered.

Two 5-second CPU samples, at 59 min and at 123 min, show the same busy functions:

- `tui.presentation.SearchProjection.create`, most samples at `presentation.zig:2008`
- `tui.buffer.buildSearchCandidates`
- `tui.buffer.buildWithComments`
- `tui.frame.buildVisualRowsWithOptions`
- `gwidth.gwidth` and the grapheme iterator, through `tui.render.nextVaxisGrapheme`
- hash map growth of `SourceRowKey` and `NavigationIndex`

The raw logs and samples stay in a local folder outside the repository, because they hold the PullRequest id.

## Suspected cause

Not proved.
bbr probably rebuilds the complete Search Projection of the Review each time File content arrives.
Each rebuild costs time in proportion to the Files that already have content.
So the total work grows with the square of the File count.
The idle phase at the end can mean a slow final rebuild or a loop that rebuilds without new input.

`SearchProjection.create` has three callers in `src/tui/presentation.zig`, near lines 2914, 4231, and 4549.

## What to do

1. Reproduce offline with a fixture Review of about 600 Files, with no Bitbucket request.
2. Count the `SearchProjection.create` calls and their cost for one cold Review Search.
3. Find whether the rebuild loop can repeat with no new input, and fix that first.
4. Make the work for one arriving File independent of the Review size, or batch the rebuilds.
5. Check whether the rebuild runs on the input and paint path in the real app. If it does, bbr also freezes during a cold search.
6. Add a test that fails when a cold Review Search on the fixture does more than a fixed number of projection rebuilds.
7. Run S4 of the M28 benchmark again on the largest PullRequest after the fix.

## Comments
