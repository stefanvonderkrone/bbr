# Keep maintenance and dropped input messages

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure
Blocked by: none

Source: [ticket 04](04-record-a-failed-retry-of-a-user-input.md).

## Problem

A Review Search completion can clear a message when it opens a pending File.
The Draft save and mutation retries show an allocation failure without a record.
A dropped non-speculative enrichment result replaces a message even when a later check queues the File again.
The failed enrichment build has the same message problem.

## Proposal

Mark each Review Search opening as input or completion.
Use `failDroppedInput` for the Draft retries.
Keep the shown message when a dropped enrichment loses only maintenance work.
Check whether a drop also cancels a pending reading location from a Session replacement.
Keep one record per failure with its existing operation and phase.

## Acceptance criteria

- [ ] A Presentation test reaches a completion opening a pending File, or the code proves why it cannot.
- [ ] Completion openings cannot clear the message before the acquisition pump.
- [ ] Red Presentation tests prove both Draft retry failures need one record.
- [ ] A red Presentation test proves a maintenance enrichment drop must keep the shown message.
- [ ] The pending reading location decision and the same-pattern build result have evidence.
- [ ] Each message rule appears once in `CODING_STANDARDS.md`.
- [ ] The unit tests, format check, agent document check, and diagnostics check pass.
- [ ] No debug marker remains, and the Worktree is clean.

## Comments

### 2026-11-21 scope

The tests use `Presentation.dispatch`, `takeCommand`, and `projection`.
No live Bitbucket request or live TUI run is part of this work.
Each failing test commit precedes its fix commit.
The initial inspection found a second production `queueFileEnrichment(..., false)` caller in `selectVersion`.
The inspection must account for that user input before it classifies every non-speculative result as maintenance work.

### 2026-11-21 completion opening probe

The new "M21 kernel Review Search completion openings keep the selected File from eviction" test reaches both completion callers.
It selects an evicted File, opens it, accepts its enrichment, and makes the destination build stale with a height resize.
The File has content at both completion openings.
The test passes with the old unconditional clear too, so it is not red proof for the pending branch.

`dispatch` calls `holdReviewSearchPreview` after every input.
The Preview holds the selected File before either completion can run.
`reviewSearchOpeningFile` requires the current selected occurrence to match the opening identity.
Enrichment admission then stages that File's result and commits it before the completion opens the occurrence.
The hold prevents that commit or another cache update from evicting the File.
The destination retry also requires the same selected occurrence in `acceptViewBuild`.
Thus the test cannot make that selected content pending through cache eviction at either completion.
The signature still states the rule with `input` and `completion`.
Both completion callers pass `completion`, and only `input` can clear before the acquisition pump.
