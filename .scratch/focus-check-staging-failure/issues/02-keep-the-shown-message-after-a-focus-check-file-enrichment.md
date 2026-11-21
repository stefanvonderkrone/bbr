# Keep the shown message after a File Enrichment queue in the focus check

Status: resolved
Blocked by: none

Source: [ticket 01](01-keep-the-session-after-a-failed-focus-check-staging.md), its Completion names this judgement call.

## Problem

The focus check queues the File Enrichment of the active File through `queueFileEnrichment(published, file_index, false)` in `ensureFocusedEnrichment`. A successful queue ends with `self.action_error = null`. So the focus check clears any message, also a message that an earlier input of the same event showed, such as `action_refused`.

The focus check is maintenance. It runs after each event, so its success must not clear the outcome of the event. PR #36 decided the same case for the Review Search retry in `retryReviewSearchQuery`: the retry saves `shown = action_error` before the queue, and a success restores it unless it is the `out_of_memory` message of the earlier failed queue.

## Proposal

Apply the rule of `retryReviewSearchQuery` to the File Enrichment of the active File in the focus check. A success clears only the `out_of_memory` message that an earlier failed queue showed.

## Acceptance criteria

- [x] A test through the Presentation interface shows a message, then dispatches `ensure_focused_enrichment`, which queues the File Enrichment of the active File. The message stays. The test fails before the fix.
- [x] The same test shows that a successful queue after a failed queue clears the `out_of_memory` message of that failure.
- [x] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.

## Comments

### 2026-11-21 fix

The success of `queueFileEnrichment` sets `action_error` to null, also when a message of the same event shows. The focus check now queues the File Enrichment of the active File through `queueMaintenanceFileEnrichment`. That helper saves the shown message before the queue. After a queue that marks the File loading, it restores the message unless the message is `out_of_memory`, as `retryReviewSearchQuery` does. A refused queue, such as a path over the length limit, still shows `action_refused`. [Ticket 03](03-record-a-failed-review-search-acquisition-queue.md) lists it.

## Completion

2026-11-21, branch `focus-check-staging-failure`.

- `queueMaintenanceFileEnrichment` records a failed queue once as `.file_enrichment`, `.prepare`, shows `out_of_memory` only when no message shows, and keeps the shown message after a success.
- The test "M21 kernel focus check File Enrichment of the active File keeps the shown message" failed before the fix with `expected .action_refused, found null`. It passes now. Its second case shows that a success after a failed queue clears the `out_of_memory` message.
- Commits: `b9b65640` (red test) and the fix commit after it.
- Checks: `zig build test-search-kernel` exit 0, `zig build test` exit 0.
