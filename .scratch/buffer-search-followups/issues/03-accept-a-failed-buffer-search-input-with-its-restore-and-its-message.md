# Accept a failed Buffer Search input with its restore and its message

Status: needs-triage
Blocked by: none

Source: [the query edit clear order ticket](../../query-edit-clear-order/issues/01-clear-before-the-maintenance-steps-of-a-query-edit.md), sections "OCR round 5" and "OCR round 6". Each section has the first open finding and its decision.

## Problem

This ticket holds two faults of an accept after a failed Buffer Search input. Both faults close the input without the result that the user expects.

1. The user edits a query. A scan of the edited query fails. The restore build of that failed scan then fails too. When the user presses the Enter key during or after that work, the input closes. But the view keeps the preview of the previous query. A Resolved Thread that the previous preview expanded stays open. `BufferSearchState.saved_disclosures` stays set until the next search.
2. The work of the input fails with `out_of_memory` at a Buffer Search failure site. When the user presses the Enter key after the failure, the input closes. The message disappears. So the accept opens nothing. The user does not see why.

## What is known about the cause

The evidence comes from a read of `src/tui/presentation.zig` on `main` and from the tests that the source ticket names. No test reproduces either fault yet.

The shared cause is that the input keeps no record of its failure.
`BufferSearchInput.failPendingScan` drops the batch.
Every failure site of the input calls it.
After that, an input that failed looks like an input whose scan has no batch.
So `acceptBufferSearch` cannot know that a restore is due or which message says why nothing opened.

For fault 1:

1. `failBufferSearchScan` queues the restore build and keeps `accept_when_ready`.
2. When that build fails, `acceptBufferDisclosure` calls `failPendingInput`, which runs `acceptBufferSearch` when an Enter key waits.
   When the build cannot queue, `failBufferSearchScan` calls `failPendingInput` too.
3. `acceptBufferSearch` installs a null batch and a null active occurrence. It queues no build.
4. Later, `clearBufferSearchActive` returns early, because no occurrence is active. So nothing restores the disclosures.

An Enter key after the failed restore takes the same path through `acceptBufferSearch`. This case comes from a read of the code. No test checks it.
`cancelBufferSearch` has no such fault. It compares the expanded disclosures with `saved_expanded_disclosures` and queues a `.restore` build.
But a cancel and a failed scan restore to different baselines.
`saved_expanded_disclosures` holds the disclosures at the open of the input. So it keeps a Resolved Thread that an earlier accepted search expanded.
The restore of `failBufferSearchScan` comes from `queueBufferDisclosure` without an occurrence. Its target is `buffer_search.saved_disclosures`.
That field holds the disclosures before the first preview or accepted search that is still in effect.
So it also collapses the thread of an earlier accepted search, as a scan without matches does.

The test "M21 kernel a failed restore of a failed Buffer Search scan shows the build failure" pins the preview while the input stays open. `docs/rules/tui-state.md` documents that limit. The test "M21 kernel an Enter key during a failed Buffer Search scan closes the input" checks the `.failed_restore` case. But it does not check the rows of the view.

For fault 2:

1. The failure sites call `failDroppedInput` or `showError(.out_of_memory)` after `failPendingInput`. The input stays open without a batch.
2. A later Enter key has the origin `.user`.
   For an input without a batch, `acceptBufferSearch` calls `clearErrorExcept` with only `buffer_search_scan_failed` and `buffer_search_no_matches`.
   So it clears `out_of_memory`.
3. The same path also clears `buffer_build_failed` after a failed input build or a failed restore. Triage must decide whether that message is part of this fault.

An accept without a batch keeps only the two search messages. That rule comes from "OCR round 2" of the source ticket. So the fix of fault 2 changes that rule.

## Proposal

Give `BufferSearchInput` a record of its failure. `failPendingInput` sets it. A query edit clears it. It holds two facts:

- whether the view still shows a preview that a restore must undo
- the message that says why the input has no batch

Then `acceptBufferSearch` uses the record:

- When a restore is due, the accept queues a `.restore` build to the baseline of the failed scan.
  That baseline is `buffer_search.saved_disclosures`, the target of the restore of `failBufferSearchScan`.
  The target is not `saved_expanded_disclosures`, because that field keeps the thread of an earlier accepted search open.
- The accept keeps the message of the record.
  It clears other messages by the rule of `clearError`.
- The `.restore` build carries the message of the record in `result_error`, as the restore of `failBufferSearchScan` carries `buffer_search_scan_failed`.
  A `.restore` build has the origin `.buffer_search`.
  A message of a failed input build or a failed restore has the same origin.
  Without `result_error`, the landing of the `.restore` build calls `clearError` and removes the kept message.
  With `result_error`, the landing shows the message again.

Triage must decide which message the record keeps after a failed restore.
`buffer_build_failed` says why the earlier restore failed. But after the new `.restore` build lands, that build failure no longer applies.
`buffer_search_scan_failed` says why the accept opened nothing.

A `.restore` build that fails or cannot queue after the accept must not loop. It shows its message. The view keeps the preview.

Open question: who releases `saved_disclosures` after the accept of fault 1? The accept can release it. Or the queued `.restore` build can own the release, as in `cancelBufferSearch`.

## Acceptance criteria

- [ ] A red test through `Presentation.dispatch`, "M21 kernel an accepted Buffer Search after a failed restore collapses the preview of the previous query", fails on `main`.
  It covers an Enter key during the failed work and an Enter key after it.
  One case starts with no accepted search.
  Another case first accepts a search that expands a Resolved Thread.
  Then it edits the query of a new input to a scan that fails.
  The test then lands the `.restore` build of the accept.
  The view must then have the rows of the disclosures that `buffer_search.saved_disclosures` held at the failure.
  In the second case, the thread of the earlier accepted search must also close, as after the restore of `failBufferSearchScan`.
  `saved_disclosures` must be null.
  After the `.restore` build lands, the status must show the message that triage chose for the record.
- [ ] A red test, "M21 kernel an accepted Buffer Search keeps the failure message of its input", fails on `main`.
  It fails the input work with `out_of_memory`.
  Then it presses the Enter key.
  The message must stay `out_of_memory` after the accept.
  When the failure left a preview, the message must also stay after the `.restore` build of the accept lands.
  A message of another path must still clear.
- [ ] The test "M21 kernel a Buffer Search input that fails after a query edit opens no occurrence of the previous query" passes with the new accept.
  On `main`, its `.input_build` case with `enter_first` expects no build from `completeTestDisclosureBuilds`.
  After the fix, the accept in that case queues a `.restore` build, so the case must expect that build.
- [ ] `docs/rules/tui-state.md` states the new accept rule once, in the section "Background work keeps an unrelated action error".
  The fix updates three old rules of that section.
  The first is the rule that an accept without a batch keeps only `buffer_search_scan_failed` or `buffer_search_no_matches`.
  The second is the rule for an Enter key during pending work of the input, with the accept in `failPendingInput`.
  The third is the rule for a restore of `failBufferSearchScan` that cannot queue or fails.
  That rule says that the view keeps the previous preview and `saved_disclosures`.
  After the fix, that rule holds only until the accept.
  The Enforcement paragraph of that section names both new tests.
- [ ] The open question has an answer in this ticket.
- [ ] `zig build test` exits with 0.
