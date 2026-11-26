# Clear before the maintenance steps of a Review Search query edit

Status: needs-triage
Blocked by: none

Source: the Standards and Spec reviews of ticket 09 in `.scratch/focus-check-staging-failure/` (PR #45).

## Problem

1. `setReviewSearchQuery` calls `clearError` at the end of its success paths.
   Before that, `discardQueuedReviewSourceScans` and, for an empty query, `releaseReviewSearchHolds` can reach `finishSearchLease`, then `stageCacheBuild`, then `failMaintenance`.
   A user query edit runs with the origin `.user`, so its clear removes the `out_of_memory` message of that failed staging.
   The failure has its record, but the user sees no message.
   The rule "A user input clears before its own steps that can show a failure" in `docs/rules/tui-state.md` does not hold here.
   The search destination completion near `discardQueuedReviewSourceScans` and `releaseReviewSearchHolds` in `acceptBufferDisclosure` can have the same order. Nobody traced its origin.
2. `openReviewSearch` runs the reopened query retry and then the acquisition pump.
   Both run as `.review_search`.
   When the retry fails with `out_of_memory` and the next allocation succeeds, the pump's successful `queueFileEnrichment` clears the message of the retry.
   `std.testing.FailingAllocator` keeps failing after its first failure, so no current test can make this case.
   With a lasting allocation failure, the pump fails too, and `failMaintenance` keeps the message.
   The focus check of PR #45 (ticket 10) runs the same reopened query retry right before the same pump while Review Search is open, so the case also applies there. The fix must cover both `openReviewSearch` and the focus check.

## Proposal

1. Move the `clearError` of `setReviewSearchQuery` before its first step that can show a failure. Write a red test that fails the staging of a released source scan lease during a query edit.
2. Decide whether a short allocation failure between two adjacent allocations needs a fix. If it does, write a test allocator that fails one allocation only, and decide whether the pump waits for the results of a retried query.

## Acceptance criteria

- [ ] A test fails before the fix when a query edit removes the message of its own failed staging.
- [ ] Item 2 has a decision in the ticket.
