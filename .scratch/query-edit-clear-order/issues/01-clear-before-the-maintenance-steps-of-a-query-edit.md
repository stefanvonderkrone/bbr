# Clear before the maintenance steps of a Review Search query edit

Status: resolved
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

- [x] A test fails before the fix when a query edit removes the message of its own failed staging.
- [x] Item 2 has a decision in the ticket.

## Comments

### Triage

All three cases are real. Each one has a red test through `Presentation.dispatch`.

1. Valid. `setReviewSearchQuery` called `clearError` at the end of both success paths. `discardQueuedReviewSourceScans` and, for an empty query, `releaseReviewSearchHolds` ran before it. With a cache update in flight, each release stages a cache build. When the staging cannot allocate, `failMaintenance` shows `out_of_memory` with the origin `.user`, and the clear of the same key removes it. The test "M21 kernel a Review Search query edit shows the failure of its cache staging" failed with `expected .out_of_memory, found null`.
2. Valid. The `.review_destination` branch of `acceptViewBuild` closes Review Search. It discards the queued source scan and releases the holds, and then it calls `clearError`. The completion has the origin `.buffer` from `DisclosureBuild.Kind.errorOrigin`, and `failMaintenance` shows its message with the same origin, so the clear removes it. The test "M21 kernel a Review Search destination shows the failure of its cache staging" failed with `expected .out_of_memory, found null`.
3. Valid for `openReviewSearch` and for the focus check. A test allocator that fails one allocation only, `FailOnceAllocator`, fails the queue slot of the reopened query retry. The pump then queues the Files, and its `queueFileEnrichment` clears the `.review_search` message of the retry. The test "M21 kernel a successful acquisition pump keeps the failure of the Review Search query retry before it" failed with `expected .out_of_memory, found null`, also with the loop order reversed so that the focus check case runs first.

The ticket was fully specified after this triage, so it went to `ready-for-agent` and then to `claimed`.

### Decision on item 2

A short allocation failure between two adjacent allocations needs a fix, because the experiment shows that the message is lost while the failure has its record.

The pump does not wait for the results of the retried query. The fault is not the order of the retry and the pump. The fault is that a clear removed a message that a step of the same event showed. A reorder cannot fix it, because the retry and the pump share the origin `.review_search` and both must run in the event.

The fix is in `clearError`. `Presentation.event_serial` counts the events, and each `ShownError` holds the serial of the event that showed it. A clear never removes a message of the event that runs. A failed maintenance step that keeps an older message records itself in `kept_failure` through `showMaintenanceError`. A later clear of the same event shows that failure instead of null. So the order of a clear and the steps of its event no longer matters, and the same change fixes items 1 and 2. The clear order rule in `CODING_STANDARDS.md` is gone, because its mistake can no longer happen.

## Completion

The fix changes the clear rule, so the order of a clear and the steps of its event no longer matters. It does not move the clears.

- `d89271b5`, `12c83975`, and `ba0ab9f4` add the red tests for the query edit, the Review Search destination, and the pump after a failed query retry. Each test failed with `expected .out_of_memory, found null`.
- `a3b96cea` adds `event_serial`, `ShownError.event`, `kept_failure`, and `showMaintenanceError`. It removes the clear order rule and the two gaps from the docs.
- `96d6ca80` makes `tools/check_action_errors.py` reject a test of `action_error == null` in `Presentation` outside `showMaintenanceError`. On the code before the fix, the check names the three old keep sites.
- The last fix commit applies the review findings. A kept failure keeps the origin of its step, the query edit test checks that the next key clears, and the docs state the rule once.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.

Review: a readonly review found no correctness bug. It found the origin of a kept failure, a missing staleness test, and a duplicate rule, and the last fix commit fixes them. Two findings are open and documented. The check reads only `action_error == null`, and the rule doc says so. The span arithmetic of the check is correct, and it stays as it is.

