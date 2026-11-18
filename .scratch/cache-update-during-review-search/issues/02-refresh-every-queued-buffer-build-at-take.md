# 02: Refresh every queued Buffer build when a worker takes it

Status: needs-triage
Blocked by: 01

## Summary

[Ticket 01](01-evict-the-files-that-review-search-releases.md) gives the cache update the two rules of the enrichment build.
At most one waits in the queue and keeps its place, and `takeCommand` gives it a new snapshot through `refreshQueuedBuild`.
The other build kinds still take their snapshot when they are queued.
This ticket asks whether they need the same rules.

## Evidence

A read of `src/tui/presentation.zig` at the head of ticket 01 found these facts.
No run measured them.

- `input`, `accepted`, `restore`, `general`, `clear_input`, `open_input`, `draft_save`, `draft_mutation`, and `card_destination` go to the end of the queue.
  While File Enrichment results arrive, a queued enrichment build can commit before them.
  The commit makes their snapshot stale, and their retry goes to the end of the queue again, behind the next enrichment build.
  So each of them can lose one full run for each enrichment commit while the results arrive.
- `view` goes in before the queued enrichment build, and `review_destination` goes to the front. They lose at most one run.
- `queueAcceptedDisclosure` removes a queued `cache_update` build and leaves `pending_cache_update` set.
  `ensureFocusedEnrichment` then returns early while the focus does not change, so the budget waits for the next lease release.
  It also removes `review_destination` and `card_destination` builds and leaves `destination_pending` and `pending_card_destination` set.

## What to decide

Measure how many runs a draft save, a Draft mutation, and a card destination lose while Review Search acquires the Files of a large Review.
If the loss is real, give each kind a new snapshot at take.
The intent fields of each kind must survive the new snapshot, such as the target and the destination of `input`, and the geometry and the active File of `view`.
The switch in `refreshQueuedBuild` names every kind, so the change for one kind is one arm.

## Comments
