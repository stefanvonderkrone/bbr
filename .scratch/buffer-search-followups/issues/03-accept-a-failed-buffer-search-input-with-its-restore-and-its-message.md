# Accept a failed Buffer Search input with its restore and its message

Status: needs-triage
Blocked by: none

Source: [the query edit clear order ticket](../../query-edit-clear-order/issues/01-clear-before-the-maintenance-steps-of-a-query-edit.md), sections "OCR round 5" and "OCR round 6". Each section has the first open finding and its decision.

## Problem

This ticket holds two faults of an accept after a failed Buffer Search input. Both faults close the input without the result that the user expects.

1. The user edits a query. A scan of the edited query fails. The restore build of that failed scan then fails too. When the user presses the Enter key during or after that work, the input closes. But the view keeps the preview of the previous query. A Resolved Thread that the previous preview expanded stays open. `BufferSearchState.saved_disclosures` stays set until the next search.
2. The work of the input fails with `out_of_memory` at a Buffer Search failure site. When the user presses the Enter key after the failure, the input closes. The message disappears. So the accept opens nothing. The user does not see why.

The fix also closes a gap that the restore of the accept and the restore of `failBufferSearchScan` share.
The landing of each restore can replace a later error of another path.
The section "Proposal" describes it.

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
- The landing of the `.restore` build keeps a later error of another origin.
  Take this order of events.
  The accept queues the `.restore` build.
  Then a completion of another path shows its error.
  Then the `.restore` build lands.
  The status must then show the later error.
  One way is to show `result_error` only when no error shows or the shown error has the origin `.buffer_search`.
  This follows the rule "Background work keeps an unrelated action error" in `docs/rules/tui-state.md`.

`main` has the same gap in the restore of `failBufferSearchScan`, so the fix covers both restores.
That restore is an input build, and `acceptBufferDisclosure` lands it.
`acceptBufferDisclosure` calls `showError` with `result_error` and does not read the shown error.
`acceptAcceptedDisclosure` does the same for the `.restore` build of the accept.
So `main` has no keep that the fix can reuse.
On `main`, the landing replaces a later error of another origin with `buffer_search_scan_failed`.
With an Enter key during the restore, the landing then runs the accept with the origin `.buffer_search`.
That accept keeps an error of another origin, but the landing already replaced it.
So the user never sees the later error.
This case comes from a read of the code. No test checks it.
The fix applies the same keep to both landings.

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
  In each case, the restore build of that failed scan fails or cannot queue.
  This precondition holds for the Enter key during the failed work and for the Enter key after it.
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
  Another case shows an error of another origin after the accept queues the `.restore` build and before that build lands.
  The later error must stay after the build lands.
- [ ] A red test, "M21 kernel a restore of a failed Buffer Search scan keeps a later unrelated error", fails on `main`.
  The scan fails after an edit from a query whose preview expanded a Resolved Thread.
  This is the setup of the test "M21 kernel a failed restore of a failed Buffer Search scan shows the build failure".
  So `failBufferSearchScan` queues its restore.
  Before the restore lands, a completion of another path shows its error.
  One case presses the Enter key before that error shows, so the landing runs the accept.
  Another case presses no Enter key.
  The later error must stay after the restore lands.
- [ ] The test "M21 kernel a Buffer Search input that fails after a query edit opens no occurrence of the previous query" passes with the new accept.
  `completeTestDisclosureBuilds` runs each queued build and returns the count of diagnostic records.
  Where the new accept queues a `.restore` build or fails to queue one, the test must match that accept.
  The `queue_disclosure` and `queue_restore` cases with `enter_first` set `disclosure_inputs_current` to false.
  So the queue of the `.restore` build of the accept can fail there and add a record.
  Each case must expect the record count of the new accept from `completeTestDisclosureBuilds`.
  The test keeps its checks that the input closes and that the status shows the message of the new accept.
- [ ] `docs/rules/tui-state.md` states the new accept rule once, in the section "Background work keeps an unrelated action error".
  The fix updates three old rules of that section.
  The first is the rule that an accept without a batch keeps only `buffer_search_scan_failed` or `buffer_search_no_matches`.
  The second is the rule for an Enter key during pending work of the input, with the accept in `failPendingInput`.
  The third is the rule for a restore of `failBufferSearchScan` that cannot queue or fails.
  That rule says that the view keeps the previous preview and `saved_disclosures`.
  After the fix, that rule holds only until the accept.
  That rule also says that the restore shows `buffer_search_scan_failed` again.
  After the fix, the restore keeps a later error of another origin.
  The Enforcement paragraph of that section names the three new tests.
- [ ] The open question has an answer in this ticket.
- [ ] `zig build test` exits with 0.
