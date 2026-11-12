# 04: Keep a Buffer rebuild after a Review Search selection move

Status: needs-triage
Blocked by: none

## Summary

[Ticket 03](03-move-the-review-search-selection-without-a-full-projection.md) recorded an open point:
a Buffer rebuild that starts before a Review Search selection move could publish its ranges with the selection of its start.

A read of the code on 2026-11-12 at commit `cf2f945` shows that this does not happen.
It shows a different cost instead.
A selection move during a Buffer rebuild throws the rebuild away and runs it again in full.

## Evidence

All paths are in `src/tui/presentation.zig`.

A `DisclosureBuild` copies `review_search.selected` into `review_selected` when it starts.
It projects its `review_ranges` with that selection.

Each admission that takes `job.review_ranges` first compares `job.review_selected` with the current selection:

| Admission | Check | On a mismatch |
| --- | --- | --- |
| `acceptBufferDisclosure`, for an input rebuild | `same_review` | `retryStaleBufferDisclosure` |
| `acceptViewBuild` | `job.review_selected != published.review_search.selected` | `retryContentBuild` |
| `acceptAcceptedDisclosure` | `job.review_selected != published.review_search.selected` | `retryAcceptedDisclosure` |

So no admission publishes ranges with an old selection.
But a mismatch makes the Presentation queue a new rebuild of the whole Buffer.
On PullRequest A, one rebuild costs about 0.15 seconds of CPU, see [ticket 01](01-coalesce-file-enrichment-rebuilds.md).
Each selection move during a rebuild adds one more rebuild, so fast moves during a rebuild can delay the rebuild for a long time.

The runner did not measure this. The evidence is a read of the code.

## What to build

A selection move does not make a Buffer rebuild stale.
When only the selection differs, the admission takes the rebuild and marks the active ranges for the current selection with `markActiveSearchRanges`.
A rebuild whose Review Search occurrences differ stays stale, as today.

## Acceptance criteria

- [ ] A test moves the Review Search selection while a Buffer rebuild runs, for each admission in the table. The Presentation admits the rebuild without a new rebuild.
- [ ] After the admission, the active ranges belong to the current selection, and they are the same as a full projection with that selection.
- [ ] A rebuild whose Review Search occurrences changed is still rejected.
- [ ] `zig build test` passes.

## Comments
