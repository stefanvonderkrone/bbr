# Record a failed destination retry

Status: needs-triage
Blocked by: none

Source: the merge of `main` at `b6b31d6a` into the branch `m29-comment-overview`, commit `06e62ca9`.
That `main` commit merged the work of [the query edit clear order ticket](../../query-edit-clear-order/issues/01-clear-before-the-maintenance-steps-of-a-query-edit.md).
The merge agent found this fault and did not fix it.

## Problem

The user opens a destination. Later, a completion queues the build of that destination.
When that queue fails, the user sees `out_of_memory`.
But the diagnostics have no record of the failure.
So a report of the failure has no cause and no source location.
No later check queues the destination again. So the destination never opens.

These paths have the fault on `main`:

1. The user opens a Review Search hit. Its `.review_destination` build is stale at its completion.
   `retryContentBuild` calls `openReviewSearchOccurrence`, and the queue in `queueReviewSearchDestination` fails.
   The message has the origin `.buffer`.
2. The user opens a Review Search hit in an evicted File. The File Enrichment build of that File lands.
   `acceptViewBuild` calls `openReviewSearchOccurrence`, and the queue fails.
   The message has the origin `.file_enrichment`.
3. The user presses the Enter key on a Draft in the Submission Overlay. Its `.card_destination` build is stale at its completion.
   `retryContentBuild` calls `queueCardDestination`, and the queue fails.
   The message has the origin `.buffer`. The Submission Overlay shows again.
4. The first `.card_destination` build finds no row for the card.
   `acceptViewBuild` queues a second build with `destination_attempt` 1, and the queue fails.
   The message has the origin `.buffer`. The Submission Overlay shows again.

The branch `m29-comment-overview` adds the kind `.overview_destination` with the same gap.
Its `retryContentBuild` calls `queueOverviewDestination`.
That function shows `out_of_memory` after a failed queue and writes no record.
That branch must follow the fix when it merges `main`.

## What is known about the cause

The evidence comes from a read of `src/tui/presentation.zig` on `main` and on `m29-comment-overview`.
No test reproduces the fault yet.

[A dropped user input shows its failure](../../../CODING_STANDARDS.md#a-dropped-user-input-shows-its-failure) says that such a retry calls `failDroppedInput`.
That function records the cause once and shows `out_of_memory`.
The standard names the `.draft_save` and `.draft_mutation` prongs of `retryContentBuild`.
It does not name the two destination prongs.

The destination paths show the message through helpers that write no record:

- `openReviewSearchOccurrence` calls `reviewSearchAllocationFailed` when `queueReviewSearchDestination` fails.
  `reviewSearchAllocationFailed` only calls `showError(.out_of_memory)`.
- `failCardDestination` clears `pending_card_destination`, calls `showError`, and shows the Submission Overlay again.
  Its caller passes `.out_of_memory`, but `failCardDestination` gets no cause.

The two helpers also serve the direct user paths.
These are the Enter key on a Review Search hit and the Enter key in the Submission Overlay.
[A boundary records every error except error.Reported](../../../docs/rules/diagnostics.md#a-boundary-records-every-error-except-errorreported) also asks for a record on those paths.
This ticket does not decide the record count of the direct paths.

`tools/check_diagnostics.py` accepts each of these sites.
A switch prong that names `error.OutOfMemory` is the sanctioned drop of [A catch captures and records its cause](../../../docs/rules/diagnostics.md#a-catch-captures-and-records-its-cause).
The standard says so in its "No check" paragraph.

The same gap exists in two admissions of `acceptViewBuild`.
A failed copy of `job.disclosures` for a `.review_destination` build shows `out_of_memory` and writes no record.
A failed copy for a `.card_destination` build calls `failCardDestination` with `.out_of_memory`.
These are admission failures, not queue failures.
Triage decides whether this ticket covers them.

## Proposal

Each failed queue of a destination at a completion calls `failDroppedInput`.
It keeps the current state changes.
These are `destination_pending`, `pending_card_destination`, and the Submission Overlay.
One way is to give `reviewSearchAllocationFailed` and `failCardDestination` the cause and a record.
That way also adds a record to the direct user paths.
Another way is to record only at the completion sites.
Both ways meet the acceptance criteria.

The fix adds the destination prongs to the list of the standard.
It also says which paths of `openReviewSearchOccurrence` are a completion.

Option for a check, from the `correct` skill: `tools/check_diagnostics.py` can count each `error.OutOfMemory` prong in Presentation that writes no record.
A prong writes a record when it calls `reportFailure` or a helper from `recording_helpers`.
A rough script with the parse of that check counts 91 such prongs in `src/tui/presentation.zig` on `main`.
So the check needs a per-file baseline, as `tools/diagnostic_catch_baseline.txt` has.
It fails when a change adds a prong.
Its error names `failDroppedInput` and `failMaintenance` as the fix.
It does not see paths 1 and 2, because `retryContentBuild` reaches the prong through `openReviewSearchOccurrence`.
A narrower rule can require that each prong in a function that queues work again calls `failDroppedInput`, `failMaintenance`, or `settleMaintenance`.
That rule has the same blind spot for paths 1 and 2.
Triage decides whether either check earns its place.

## Acceptance criteria

- [ ] A red test, "M21 kernel failed Review Search destination retry records the dropped input once", fails on `main`.
  It runs with `.diagnostic_state = .on`.
  One case makes a `.review_destination` build stale and fails the queue of its retry.
  `disclosure_inputs_current = false` before the completion does both, because `DisclosureBuild.create` then fails with `error.OutOfMemory`.
  A `FailOnceAllocator` or a `FailingAllocator` that fails the queue also meets this criterion.
  Another case opens a hit in an evicted File and fails the queue after the File Enrichment build lands.
  The setup of "M21 kernel opening a Review Search hit in an evicted File clears an older message" reaches that path.
  Each case shows an older message before the completion.
  After the completion, the status shows `out_of_memory`.
  The commands hold exactly one `report_diagnostic` with the cause `error.OutOfMemory`.
  `destination_pending` is false, and the Review Search Overlay stays open.
- [ ] A red test, "M21 kernel failed card destination retry records the dropped input once", fails on `main`.
  It runs with `.diagnostic_state = .on`.
  One case makes a `.card_destination` build stale and fails the queue of its retry, as above.
  Another case fails the queue of the second build with `destination_attempt` 1.
  No test reads `destination_attempt` today. When no test can reach that case, the ticket says why.
  After the completion, the status shows `out_of_memory`.
  The commands hold exactly one `report_diagnostic` with the cause `error.OutOfMemory`.
  `pending_card_destination` is null, and the Submission Overlay shows again.
- [ ] The tests do not pin the `operation` and the `phase` of the record.
  `failDroppedInput` writes `.completion` and `.admission`, but another correct fix can write other values.
- [ ] [A dropped user input shows its failure](../../../CODING_STANDARDS.md#a-dropped-user-input-shows-its-failure) names the destination retries.
  It names the two new tests.
- [ ] Triage records its decision on the two admissions of `acceptViewBuild` in this ticket.
- [ ] Triage records its decision on the check option in this ticket.
- [ ] `zig build test` exits with 0.
