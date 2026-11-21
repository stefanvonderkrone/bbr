# Derive the event class in dispatch

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

Classify each `OwnedInput` kind once in `Presentation.dispatch` with an exhaustive switch.
Store the class for the event in a field.
Remove the `trigger` parameter, and let `openReviewSearchOccurrence` read the class.

## Acceptance criteria

- [x] Red Presentation tests prove that each `selectVersion` queue failure needs one record.
- [x] `openReviewSearchOccurrence` takes no trigger, and it clears the message only for a user input.
- [x] A new `OwnedInput` kind without a class does not compile.
- [x] The input test and the completion test of the occurrence opening pass.
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
Thus `resize` and `resize_viewport` are completions, not user inputs.
It also found an Enforcement paragraph that claimed a reason and a test that cannot fail.
Commit `70270450` fixes both and moves the unchecked parts to `CODING_STANDARDS.md`.

The Spec review claimed that a stale `review_destination` retry can reach the clear with a pending File.
`acceptViewBuild` retries only while the job occurrence equals the selected occurrence.
The Review Search Preview holds the File of the selected occurrence, so no cache update evicts it.
The round 5 probe in ticket 05 reaches both completion callers and finds the File with content.
So no completion test is added, and `CODING_STANDARDS.md` records the reason.

## Answer

`selectVersion` calls `failDroppedInput` in both `catch` handlers.
`Presentation.dispatch` sets `event_class` with one exhaustive switch over `OwnedInput`.
`openReviewSearchOccurrence` takes no trigger and reads `event_class`.

## Completion

Commit `636d1110` adds the red tests "M21 kernel failed Selected Version view build queue shows its failure once" and "M21 kernel failed Selected Version enrichment queue shows its failure once".
Both fail at `const command = presentation.takeCommand() orelse return error.TestExpectedRecord;`, and `zig build test-search-kernel` exits 1 with 167 of 169 tests passing.
With only the first `catch` fixed, only the enrichment queue test fails, so each test reaches its own `catch`.
Commit `5ccafab4` fixes both, and commit `7ef3f85a` names `selectVersion` in `CODING_STANDARDS.md`.

Commit `e0c68a63` adds `EventClass` and removes the trigger.
An added `OwnedInput` kind without a class fails with `src/tui/presentation.zig:6760:28: error: switch must handle all possibilities`.
The probe was reverted.
A clear for completions only fails "M21 kernel opening a Review Search hit in an evicted File clears an older message".
An unconditional clear passes every M21 kernel test, because no completion reaches the clear.

The final `zig build test --summary all` run exits 0 with 59 of 59 steps and 1728 of 1728 tests passing.
`zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, and `python3 tools/check_diagnostics.py` exit 0.
