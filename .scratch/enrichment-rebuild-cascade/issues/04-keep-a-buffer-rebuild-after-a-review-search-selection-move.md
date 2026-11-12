# 04: Keep a Buffer rebuild after a Review Search selection move

Status: ready-for-agent
Blocked by: none

## Summary

[Ticket 03](03-move-the-review-search-selection-without-a-full-projection.md) recorded an open point:
a Buffer rebuild that starts before a Review Search selection move could publish its ranges with the selection of its start.

A read of the code on 2026-11-12 at commit `cf2f945` shows that this does not happen.
It shows a different cost instead.
A selection move during a Buffer rebuild throws the rebuild away and runs it again in full.

A live run on 2026-11-12 at commit `46b33d4` confirms the cost.
While Review Search acquires the Files of a large Review, each selection move discards the running enrichment rebuild.
With one move every 0.5 seconds, the File acquisition takes about twice as long.

## Evidence

All paths are in `src/tui/presentation.zig`.

A `DisclosureBuild` copies `review_search.selected` into `review_selected` when it starts.
It projects its `review_ranges` with that selection.

Each admission that takes `job.review_ranges` first compares `job.review_selected` with the current selection:

| Admission | Check | On a mismatch | Selection-only mismatch in practice |
| --- | --- | --- | --- |
| `acceptBufferDisclosure`, for an input rebuild | `same_review` | `retryStaleBufferDisclosure` | No. See below. |
| `acceptViewBuild` | `job.review_selected != published.review_search.selected` | `retryContentBuild` | Yes, for `.enrichment` builds. Measured. |
| `acceptAcceptedDisclosure` | `job.review_selected != published.review_search.selected` | `retryAcceptedDisclosure` | No. See below. |

So no admission publishes ranges with an old selection.
But a mismatch makes the Presentation queue a new rebuild of the whole Buffer.

### Where the overlap happens

A selection move is possible only in the `review_search` interaction context, so only while the Review Search Overlay is open (`keymap.supportsContext`).
While it is open, `pumpReviewSearchAcquisition` keeps up to 8 File Enrichments in flight.
Each result joins an `.enrichment` build ([ticket 01](01-coalesce-file-enrichment-rebuilds.md)).
So on a large Review, an enrichment build runs during most of the acquisition, and a move almost always lands during one.
`selectReviewSearch` itself can start an Enrichment for the File of the selected occurrence, which adds builds.

The input and accepted admissions do not see a selection-only mismatch in practice.
This is a read of the code, and the live run logged none.
Their builds come from Buffer Search and disclosure actions, which the `review_search` context does not allow.
A build that starts before Review Search opens has no `review_snapshot`, so it fails on the Review Search batch, not on the selection.

### Measurement

The runner added temporary `[DEBUG-t04]` logs to a ReleaseFast build.
The logs recorded the thread CPU time of each `DisclosureBuild.build`, each retry, and each admission that failed only on the selection.
The run used `bbr local` on two commits of this repository, a Review with 187,827 Buffer rows, at 160 × 80 with an empty state directory.
The script opened Review Search with `g f`, typed `e`, and pressed Down every 0.5 seconds.
A second binary, "keep", differed in one place: `acceptViewBuild` accepted a selection-only mismatch and called `markActiveSearchRanges` with the current selection.

Runs of 30 seconds after the query:

| Run | Moves | Enrichment builds | Retries | Retries for the selection only | Candidates at the end |
| --- | --- | --- | --- | --- | --- |
| No moves, 2 runs | 0 | 63, 63 | 1, 1 | 0, 0 | 154,131 and 158,551 |
| Moves, today, 4 runs | 20 each | 78 to 82 | 16 to 20 | 15 to 19 | 15,396 to 54,658 |
| Moves, keep, 3 runs | 20 each | 63 each | 1 each | 0 each | 160,576 (all) |

Runs until Review Search counts all 160,576 candidates, with a move every 0.5 seconds:

| Run | Time to all candidates | Enrichment builds | Retries for the selection only | Build CPU time |
| --- | --- | --- | --- | --- |
| Today, run 1 | 70 s | 148 | 86 | 48.4 s |
| Today, run 2 | 72 s | 155 | not recorded | 50.3 s |
| Keep, run 1 | 33 s | 63 | 0 | 21.5 s |
| Keep, run 2 | 33 s | 63 | 0 | 20.5 s |

One enrichment build took 314 to 357 ms of CPU time, with a median of 334 ms, on this Review.
[Ticket 01](01-coalesce-file-enrichment-rebuilds.md) measured about 0.15 seconds on PullRequest A, which has about 111,700 Buffer rows.
The extra builds explain the delay: about 86 discarded builds at about 0.33 seconds each are about 28 seconds of the single worker.
A discarded build loses no File Enrichment result, because `retryEnrichmentBuild` moves its results to the front of the queued build.

## What to build

A selection move does not make a Buffer rebuild stale in `acceptViewBuild`.
When the Review Search batch is the same and only the selection differs, the admission takes the rebuild.
After it publishes `job.review_ranges`, it marks the active ranges for the current selection with `markActiveSearchRanges`.

A `.review_destination` build keeps its current checks.
It builds the destination of the occurrence that it started with, so a move to another occurrence must still drop it.

A rebuild whose Review Search batch differs stays stale, as today.

The input and accepted admissions keep their checks.
They are out of scope because no user action reaches them with a selection-only mismatch.

## Acceptance criteria

- [ ] A test through `Presentation` opens Review Search, starts an `.enrichment` build, moves the Review Search selection, and completes the build.
  The Presentation admits the build, and no `build_buffer_disclosure` command waits in the queue.
- [ ] After that admission, the published Review Search ranges are equal to the full projection with the current selection (`Published.projectReviewRanges`, the test oracle).
- [ ] A `.review_destination` build that started before a move to another occurrence is still dropped and does not move the DiffPane.
- [ ] A rebuild whose Review Search batch changed is still rejected and retried.
- [ ] In the live run above, with a move every 0.5 seconds, the enrichment build count and the time to all candidates are within 10 percent of the run without moves.
  On the Review above, that is about 63 builds and about 33 seconds.
- [ ] `zig build test` passes.

## Comments

### 2026-11-12, triage

Decision: `ready-for-agent`.

The live run confirms the claim for `acceptViewBuild` and `.enrichment` builds.
With a move every 0.5 seconds, 86 of 148 enrichment builds were discarded only because the selection moved.
Review Search needed 70 to 72 seconds instead of 33 seconds to count all candidates.
A probe binary that admitted the selection-only mismatch and marked the active ranges ran 63 builds and finished in 33 seconds, the same as a run without moves.

The runner narrowed the ticket.
The input and accepted admissions do not see a selection-only mismatch in practice, so they are out of scope.
A `.review_destination` build must keep its selection check.
The runner corrected the cost of one build for this Review and added a measurable target.

The probe worktree, the logs, and the state directory are deleted.
