# Return the query scan failure to its caller

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure (ticket 07 round)
Blocked by: none

Source: [ticket 06](06-derive-the-event-origin-in-dispatch.md) and the review of its merge round.

## Problem

`replaceReviewSearchQuery` shows `out_of_memory` when its query or its scan cannot queue.
The focus check retry, `retryReviewSearchQuery`, must keep the shown message instead.
So the retry saves `action_error` before the call and shows the saved copy again after a failure.
It writes the copy through `withErrorOrigin(kept.origin, showErrorFor, ...)`.

This copy broke once.
When main added `ShownError.key`, the copy lost the key, and the compiler did not see it.
The origin that the retry passes is a run-time value, and no check covers it.

## Proposal

`replaceReviewSearchQuery` records its allocation failure and returns `error.Reported`.
It shows no message for that failure.
Each caller picks the message:

- The retry calls `failMaintenance`, so a failed retry keeps the shown message.
- The user input paths call `failDroppedInput`, so the failure shows as before.

Remove the save and the restore in `retryReviewSearchQuery`.
Then `tools/check_action_errors.py` rejects an origin in `withErrorOrigin` that is not an enum literal, so a copied origin cannot come back.

## Acceptance criteria

- [ ] Before the change, a mutation of each path makes a named test fail.
- [ ] `replaceReviewSearchQuery` shows no message for its allocation failure, and each failure has one record.
- [ ] `retryReviewSearchQuery` has no copy of `action_error` and no `withErrorOrigin` call.
- [ ] The line check rejects `withErrorOrigin(kept.origin, ...)` from the ticket 06 code.
- [ ] No test changes, and every test passes.
- [ ] `docs/rules/tui-state.md` and `CODING_STANDARDS.md` state each rule once.
- [ ] The unit tests, format check, agent document check, action error check, diagnostics check, and doc symbol check pass.
- [ ] No debug instrumentation remains, and the Worktree is clean.

## Comments

### 2026-11-26 pin

The mutation runs use `zig build test-search-kernel test-review-recovery` on `d4301ed3`.
Each mutation was reverted.

- Without the restore: "M21 kernel Review Search keeps another message of the same event when a reopened query retry fails" and "M21 kernel Review Search keeps the PullRequest of a shown error when a reopened query retry fails" fail.
- With the restore but without the key: "M21 kernel Review Search keeps the PullRequest of a shown error when a reopened query retry fails" fails.
- Without the message of a failed scan queue: "Review recovery a Review Search query retry clears its failed scan error", "Review recovery a failed view build survives a successful Review Search query retry", and one M21 kernel test crash.
- With a second record in the failed retry: "M21 kernel Review Search keeps another message of the same event when a reopened query retry fails" and "Review recovery a Review Search query retry clears its failed scan error" fail.
- With the restore copied into the typed query edit: both "M21 kernel Review Search keeps another message of the same event when a reopened query retry ..." tests fail.
