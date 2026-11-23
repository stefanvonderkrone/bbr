# Derive the event origin in dispatch

Status: resolved
Blocked by: 05

Source: [ticket 05](05-keep-maintenance-and-dropped-input-messages.md).

## Problem

`selectVersion` is a direct user input.
When its view build or its File Enrichment cannot queue, it shows `out_of_memory` and records nothing.

`openReviewSearchOccurrence` takes a `trigger` parameter with the values `input` and `completion`.
Each caller chooses whether the shown message clears.
A future completion caller can pass `input` and clear a message that it did not set.

## Proposal

Call `failDroppedInput` in both `catch` handlers of `selectVersion`.

Give each `OwnedInput` kind one origin in `Presentation.dispatch` with an exhaustive switch.
Store the origin of the event in a field.
Remove the `trigger` parameter, and let `openReviewSearchOccurrence` read the origin.

## Acceptance criteria

- [x] Red Presentation tests prove that each `selectVersion` queue failure needs one record.
- [x] `openReviewSearchOccurrence` takes no trigger, and it clears the message only for an event from the person.
- [x] A new `OwnedInput` kind without an origin does not compile.
- [x] The occurrence opening tests for an event from the person and for an event from the App pass.
- [x] `docs/rules/tui-state.md` names the exhaustive switch as the mechanism.
- [x] The unit tests, format check, agent document check, and diagnostics check pass.
- [x] No debug instrumentation remains, and the Worktree is clean.

## Comments

### 2026-11-21 scope

The tests use `Presentation.dispatch`, `takeCommand`, and `projection`.
No live Bitbucket request or live TUI run is part of this work.
Each failing test commit precedes its fix commit.

### 2026-11-21 reviews

The Standards review found that the App sends `resize` after each event to sync the geometry.
Thus the origin of `resize` and `resize_viewport` is the App, not the person.
It also found an Enforcement paragraph that claimed a reason and a test that cannot fail.
Commit `70270450` fixes both and moves the unchecked parts to `CODING_STANDARDS.md`.

The Spec review claimed that a stale `review_destination` retry can reach the clear with a pending File.
`acceptViewBuild` retries only while the job occurrence equals the selected occurrence.
The Review Search Preview holds the File of the selected occurrence, so no cache update evicts it.
The round 5 probe in ticket 05 reaches both callers for events from the App and finds the File with content.
So no test for an event from the App is added, and `CODING_STANDARDS.md` records the reason.

### 2026-11-21 rename

The event classification is now `EventOrigin { user, app }` in the field `event_origin`.
The origin names who sent the event: the person or the App.
Ticks, worker results, the focus check, and `resize` come from the App.
The rename changes no behavior.

### 2026-11-23 merge of main

PR #46 on main adds `ErrorOrigin` and the field `event_origin: ?ErrorOrigin`.
`dispatch` sets it from `OwnedInput.errorOrigin`, an exhaustive switch over `OwnedInput`.
`showError` and `clearError` read it and take no origin.
`clearError` clears any error for `.user`, and only an error of its own origin otherwise.
`tools/check_action_errors.py` rejects a write of `action_error` outside both helpers, and a write of `event_origin` outside `dispatch` and `withErrorOrigin`.

So `EventOrigin` repeats `event_origin == .user`, and the merge removes it.
`openReviewSearchOccurrence` calls `clearError` before the acquisition pump for an evicted File.
For a user event this clears any message, as before.
For a completion it clears only an error of the completion's own origin, by the rule of main.
No completion reaches this clear, as the 2026-11-21 reviews say, so no test changes.
`clearError` takes no origin, and the exhaustive switch gives each event its origin.
Three new `withErrorOrigin` calls pass an origin: the two queues in `pumpReviewSearchAcquisition` pass `.review_search`, and `retryReviewSearchQuery` passes the origin of the error that it shows again.
The line check limits the writes of `event_origin` to `dispatch` and `withErrorOrigin`, but it does not check the origin that a caller passes.
Only the override list in `docs/rules/tui-state.md` and the tests below control these origins.
This comment replaces the earlier answer and the criterion "clears the message only for an event from the person".

The pump now queues each File as `.review_search` through `withErrorOrigin`, because it acquires Files for Review Search.
Without the override, "M21 kernel Review Search acquisition queue keeps the shown message" fails, because the queue clears the `file_enrichment_launch_failed` of its own event.
Without the `clearError` call, "M21 kernel opening a Review Search hit in an evicted File clears an older message" fails.

## Answer

`selectVersion` calls `failDroppedInput` in both `catch` handlers.
`Presentation.dispatch` sets `event_origin` with one exhaustive switch over `OwnedInput`.
`openReviewSearchOccurrence` takes no trigger and reads `event_origin`.

## Completion

Commit `636d1110` adds the red tests "M21 kernel failed Selected Version view build queue shows its failure once" and "M21 kernel failed Selected Version enrichment queue shows its failure once".
Both fail at `const command = presentation.takeCommand() orelse return error.TestExpectedRecord;`, and `zig build test-search-kernel` exits 1 with 167 of 169 tests passing.
With only the first `catch` fixed, only the enrichment queue test fails, so each test reaches its own `catch`.
Commit `5ccafab4` fixes both, and commit `7ef3f85a` names `selectVersion` in `CODING_STANDARDS.md`.

Commit `e0c68a63` adds the event classification and removes the trigger.
An added `OwnedInput` kind without an origin fails with `src/tui/presentation.zig:6760:28: error: switch must handle all possibilities`.
The probe was reverted.
A clear only for events from the App fails "M21 kernel opening a Review Search hit in an evicted File clears an older message".
An unconditional clear passes every M21 kernel test, because no event from the App reaches the clear.

The final `zig build test --summary all` run exits 0 with 59 of 59 steps and 1728 of 1728 tests passing.
`zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, and `python3 tools/check_diagnostics.py` exit 0.
