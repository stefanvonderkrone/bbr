# Return the query scan failure to its caller

Status: resolved
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

- [x] Before the change, a mutation of each path makes a named test fail.
- [x] `replaceReviewSearchQuery` shows no message for its allocation failure, and each failure has one record.
- [x] `retryReviewSearchQuery` has no copy of `action_error` and no `withErrorOrigin` call.
- [x] The line check rejects `withErrorOrigin(kept.origin, ...)` from the ticket 06 code.
- [x] No test changes, and every test passes.
- [x] `docs/rules/tui-state.md` and `CODING_STANDARDS.md` state each rule once.
- [x] The unit tests, format check, agent document check, action error check, diagnostics check, and doc symbol check pass.
- [x] No debug instrumentation remains, and the Worktree is clean.

## Comments

### 2026-11-26 pin

The mutation runs use `zig build test-search-kernel test-review-recovery` on `d4301ed3`.
Each mutation was reverted.

- Without the restore: "M21 kernel Review Search keeps another message of the same event when a reopened query retry fails" and "M21 kernel Review Search keeps the PullRequest of a shown error when a reopened query retry fails" fail.
- With the restore but without the key: "M21 kernel Review Search keeps the PullRequest of a shown error when a reopened query retry fails" fails.
- Without the message of a failed scan queue: "Review recovery a Review Search query retry clears its failed scan error", "Review recovery a failed view build survives a successful Review Search query retry", and one M21 kernel test crash.
- With a second record in the failed retry: "M21 kernel Review Search keeps another message of the same event when a reopened query retry fails" and "Review recovery a Review Search query retry clears its failed scan error" fail.
- With the restore copied into the typed query edit: both "M21 kernel Review Search keeps another message of the same event when a reopened query retry ..." tests fail.

### 2026-11-26 names

The work moved into `setReviewSearchQuery`, which returns `error.Reported` and shows no message for an allocation failure.
`replaceReviewSearchQuery` stays as the entry of the user input and calls `failDroppedInput`.
The test "M21 kernel search lease release and Review Search hold release stage eviction once" calls `replaceReviewSearchQuery("")` in a void `if`, so a non-void return would change a test.
The wrapper has four callers: the query insert, the query edit, `openReviewSearch`, and that test.

### 2026-11-26 pin gap

No test saw a failed query edit while another message shows.
The new test "M21 kernel a failed Review Search query edit shows its failure over another message" pins it before the refactor.
On `d4301ed3`, it fails when that failure keeps the shown message, and when it records twice.

## Answer

`setReviewSearchQuery` records an allocation failure with the same operation and phase as before, and returns `error.Reported`.
`retryReviewSearchQuery` calls `failMaintenance`, and `replaceReviewSearchQuery` calls `failDroppedInput`.
`reportFailure` drops a cause of `error.Reported`, so each failure keeps one record.
The save and the restore of `action_error` are gone.
`tools/check_action_errors.py` rejects a `withErrorOrigin` origin in `Presentation` that is not an enum literal.

## Completion

Commits: `9214b3c4` (ticket), `98424571` (pin test), `5114030b` (refactor), `37a1bb7d` (line check), `731cf646` (docs), and the review fix commit after it.
No existing test changed. After the refactor, `failDroppedInput` in the retry fails both "reopened query retry fails" tests, and `failMaintenance` in `replaceReviewSearchQuery` fails the new test.
The line check exits 1 on `src/tui/presentation.zig` of `d4301ed3` and `d4301ed3~1` at line 8783, and 0 on the new code.
`zig build test --summary all` exits 0 with 68 of 68 steps and 1768 of 1768 tests passing.
`zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `check_action_errors.py`, `check_diagnostics.py`, and `check_doc_symbols.py .` exit 0.
Review: the Standards and Spec reviews found no bug. The review fix commit corrects the `replaceReviewSearchQuery` comment, the `CODING_STANDARDS.md` wording for a reopened query, and the scope of the line check in `docs/rules/tui-state.md`.
The operation argument of `failMaintenance` and `failDroppedInput` has no effect for `error.Reported`. That is the ADR-0014 shape, so it stays.
