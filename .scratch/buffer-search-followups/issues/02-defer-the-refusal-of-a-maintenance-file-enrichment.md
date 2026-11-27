# Defer the refusal of a maintenance File Enrichment

Status: needs-triage
Blocked by: none

Source: [the query edit clear order ticket](../../query-edit-clear-order/issues/01-clear-before-the-maintenance-steps-of-a-query-edit.md), section "OCR round 2" (first open finding), section "CodeRabbit round 2" (item 4 and the follow-up list).

## Problem

The focus check or the Review Search acquisition can refuse a File Enrichment, because a value is too long.
Then the user sees `action_refused` at once.
This message can replace an unrelated message that the user has not read yet. An example is the failure of a Submission.

## What is known about the cause

The evidence comes from a read of `src/tui/presentation.zig` on `main`. No test reproduces it yet.

1. `queueFileEnrichment` copies five values into `BoundedText` fields of `EnrichFile`. The values are the repository name, the source commit, the destination commit, the old path, and the new path.
   When one value is too long, a non-speculative queue calls `showError(.action_refused)` and returns without an error.
2. `showError` replaces the shown message at once. It does not wait for `finishEvent`.
3. `queueMaintenanceFileEnrichment` passes the outcome of `queueFileEnrichment` to `settleMaintenance`.
   The outcome is a success, so `settleMaintenance` treats the refusal as a recovery of the File.
   It also returns true to its caller.
   The refusal comes before each allocation of the queue. So a File with a too-long value has no `out_of_memory` entry to remove. So this wrong success hides no failure today. It only makes the refusal skip the maintenance record.
4. The File stays pending, because `markLoading` does not run.
   So each later focus check queues it again and shows `action_refused` again.
5. `pumpReviewSearchAcquisition` stops at a File that stays pending after its queue.
   Its comment says that a refused path does not consume a slot. So the pump acquires no File after the refused File in that event.

Item 5 is a design choice of the pump. Triage decides whether it is part of this fault.

A user input such as `selectVersion` also calls `queueFileEnrichment` with `speculative` false.
For a user input, the message at once is right, because the user asked for the work.

The source ticket kept this out of scope. The code before that branch did the same, and the message is not `out_of_memory`.

## Proposal

Make the refusal an outcome of `queueFileEnrichment`, for example an `error.Refused` in its error set.
Then a user input shows `action_refused` at once.
`queueMaintenanceFileEnrichment` records the refusal through `showMaintenanceError` with `.action_refused`, so `finishEvent` shows it only when no message shows.
`settleMaintenance` then does not count the refusal as a success.

Open question: must a refused File stop the repeated refusal at each focus check? A File state for a refused File could stop it.

## Acceptance criteria

- [ ] A red test through `Presentation.dispatch`, "M21 kernel a refused focus check File Enrichment keeps an unrelated message", fails on `main`. It shows an unrelated message. Then it runs a focus check on a File with a path of more than 512 bytes. The unrelated message must stay.
- [ ] The same test checks that the focus check shows `action_refused` when the event ends without a message.
- [ ] A user input that queues a refused File Enrichment still shows `action_refused` at once.
- [ ] The open question has an answer in this ticket.
- [ ] `zig build test` exits with 0.
