# 06: Keep a Buffer rebuild after a Buffer Search current occurrence move

Status: needs-triage
Blocked by: none

## Summary

[Ticket 04](04-keep-a-buffer-rebuild-after-a-review-search-selection-move.md) removed the Review Search selection from `DisclosureBuild`.
A selection move no longer discards a running Buffer rebuild.
The Buffer Search current occurrence still has the old form.
This ticket asks whether it has the same cost.

## Evidence

This is a read of the code at commit `1825dd0`. Nobody measured it.
All paths are in `src/tui/presentation.zig`.

- `DisclosureBuild.create` copies `buffer_search.active` into `accepted_active`.
- `acceptViewBuild` retries a build when `job.accepted_active != published.buffer_search.active`.
- `acceptBufferDisclosure` compares it in `same_batch`, and `acceptAcceptedDisclosure` compares it for a `.general` build.

So a Buffer Search `n` or `N` can discard a running rebuild, such as an `.enrichment` or `.view` build.
The Presentation then queues the whole rebuild again.

The case differs from Review Search in one way.
`DisclosureBuild.buildFallible` passes `accepted_active` to `retainedSearchIndex` when it scans a rebuilt batch.
So the current occurrence is an input of a rebuilt batch, not only of the `active` flag of the ranges.

## Questions for triage

- Does a user reach a running rebuild with a current occurrence move? Measure it on the workload of ticket 04 with an accepted Buffer Search and `n` presses during File Enrichment.
- If yes, can the admission take the build, map the current occurrence to the published batch, and mark the ranges with `markActiveSearchRanges`, as `Published.publishReviewRanges` does for Review Search?
