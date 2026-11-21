# Keep the shown message after a File Enrichment queue in the focus check

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure
Blocked by: none

Source: [ticket 01](01-keep-the-session-after-a-failed-focus-check-staging.md), its Completion names this judgement call.

## Problem

The focus check queues the File Enrichment of the active File through `queueFileEnrichment(published, file_index, false)` in `ensureFocusedEnrichment`. A successful queue ends with `self.action_error = null`. So the focus check clears any message, also a message that an earlier input of the same event showed, such as `action_refused`.

The focus check is maintenance. It runs after each event, so its success must not clear the outcome of the event. PR #36 decided the same case for the Review Search retry in `retryReviewSearchQuery`: the retry saves `shown = action_error` before the queue, and a success restores it unless it is the `out_of_memory` message of the earlier failed queue.

## Proposal

Apply the rule of `retryReviewSearchQuery` to the File Enrichment of the active File in the focus check. A success clears only the `out_of_memory` message that an earlier failed queue showed.

## Acceptance criteria

- [ ] A test through the Presentation interface shows a message, then dispatches `ensure_focused_enrichment`, which queues the File Enrichment of the active File. The message stays. The test fails before the fix.
- [ ] The same test shows that a successful queue after a failed queue clears the `out_of_memory` message of that failure.
- [ ] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.
