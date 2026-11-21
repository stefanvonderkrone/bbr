# Keep maintenance and dropped input messages

Status: resolved
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

- [x] A Presentation test reaches a completion opening a pending File, or the code proves why it cannot.
- [x] Completion openings cannot clear the message before the acquisition pump.
- [x] Red Presentation tests prove both Draft retry failures need one record.
- [x] A red Presentation test proves a maintenance enrichment drop must keep the shown message.
- [x] The pending reading location decision and the same-pattern build result have evidence.
- [x] Each message rule appears once in `CODING_STANDARDS.md`.
- [x] The unit tests, format check, agent document check, and diagnostics check pass.
- [x] No debug instrumentation remains, and the Worktree is clean.

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

### 2026-11-21 enrichment decisions

`selectVersion` queues a non-speculative enrichment for user input too.
Its `version_restoration` survives `releaseEnrichments`, so a later focus acquisition can still restore the location.
The File reset to pending does not drop that input.

The pending reading location of Refresh or Reconciliation is different.
ADR-0012 makes that location part of the replacement behavior.
`releaseEnrichments` cancels `pending_review_location`, and no later check reconstructs the location.
That cancellation drops part of the replacement input.
The new Refresh-location test passes before and after the fix.
It requires the failure to replace an older message and record once.

`releaseEnrichments` now returns whether it canceled that location.
`dropEnrichments` then uses `failDroppedInput` for the canceled input.
Other drops keep the shown message and their existing `.completion`, `.admission` record.
A speculative-only drop keeps its record-only behavior.
The failed-build completion uses the same cancellation fact for its message.
The worker already records that build failure, so the completion adds no record.

### 2026-11-21 debug marker check

The literal repository-wide debug marker grep is not empty at the base commit.
Both `415e2942` and this round contain 45 existing documentation and skill references to that marker.
The source, build file, and tests contain none.
This round adds no marker.
The old documentation references stay unchanged because this ticket does not own them.

## Completion

2026-11-21, branch `focus-check-staging-failure`.

The Review Search opening signature separates input and completion.
Only input clears before the acquisition pump.
The completion probe reaches both callers, but the Preview hold prevents the pending state.
It is passing evidence of that invariant, not red proof of the pending branch.
Commit `f0b914c4` contains this change.

The two Draft retries use `failDroppedInput` after they clear their pending fields.
The tests "M21 kernel failed Draft save retry records the dropped input once" and "M21 kernel failed Draft mutation retry records the dropped input once" both fail before the fix.
Their exact failure line is `const command = presentation.takeCommand() orelse return error.TestExpectedRecord;`.
The red run exits 1 with 161 of 163 tests passing.
Commits `b42b4d05` and `21335235` contain the red tests and the fix.

The three "M21 kernel failed maintenance enrichment queue/snapshot/merge keeps the shown message and records once" tests fail before the fix.
Each fails with `expected .buffer_search_invalid_query, found .out_of_memory`.
The red run exits 1 with 161 of 164 tests passing.
Commits `f984e4c7` and `18db71a2` contain the red tests and the fix.
The canceled Refresh-location case already passes before the fix.
Its message still replaces an older message, with one record.

The same-pattern test is "M21 kernel a failed enrichment rebuild keeps a shown message and reports only demanded Files".
It fails with `expected .action_refused, found .buffer_build_failed`.
The red run exits 1 with 164 of 165 tests passing.
Commits `3307525f` and `0004904c` contain the red test and the fix.
Each green `zig build test-search-kernel` run exits 0.

The independent review reports no findings.
`zig build test --summary all` exits 0 on aarch64 macOS with target `native-macos.15.0`.
The first run hit the shell's 120-second timeout and exited 143.
The longer run completed all checks.
The format, agent document, diagnostics, and diff checks exit 0.
The source debug marker grep exits 1 with no matches.
The repository-wide grep still finds the 45 unchanged documentation and skill references described above.

### 2026-11-21 review-gap follow-up

The two-axis review found missing behavior evidence and unclear standards text.
This round adds that evidence without a behavior change.

The test "M21 kernel dropped Selected Version enrichment retries and restores the reading location" passes before any behavior fix.
The test takes the enrichment command directly after `select_old_version`.
It fails the result queue with the Presentation allocator and reads one completion admission record.
The later focus check queues the same File again.
The accepted enrichment restores Selected Version `old` and puts `old b` under the cursor in File 1.
Thus, the dropped result does not lose the Selected Version input.
Commit `40f19e37` adds the test.
Commit `beec6ebd` strengthens the first command assertion after review.
The first version used a helper that could queue enrichment before it read the command.
The strengthened test passes without a behavior fix too.

The test "M21 kernel failed enrichment build that cancels a Refresh location shows its failure" also passes before any behavior fix.
It fails the enrichment build while the reading location remains pending.
The completion cancels that location and replaces `action_refused` with `buffer_build_failed`.
The cursor stays at the File header, and the completion emits no second diagnostic command.
Commit `18b89d79` adds this test and documents the boolean return from `releaseEnrichments`.
That commit also renames the probe to "M21 kernel Review Search completion openings keep the shown message".

Commit `e8f6c1b9` scopes the completion rule to an occurrence opening.
It removes the duplicate record-once text and names the operation and phase of the drop record.
It uses active voice and names the refresh or Reconciliation instead of "that input".
The Presentation glossary uses "reading location" but defines no Refresh term.
The standards therefore use plain "refresh" and identify `pending_review_location` once.
No glossary change is needed.

The first follow-up review found the initial command assertion gap on the Spec axis.
The final independent review reports no findings on either the Standards or Spec axis.
Both reviews are static reviews.
The final review includes the strengthened assertion and the standards edits.

Both new tests pass before any behavior fix, so this round needs no red-to-green behavior fix.
The final `zig build test-search-kernel --summary all` run exits 0 with 167 of 167 tests passing.
The final `zig build test --summary all` run exits 0 with 59 of 59 steps and 1726 of 1726 tests passing.
The native host is aarch64 macOS, and the build target is `native-macos.15.0`.
`zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, and `python3 tools/check_diagnostics.py` exit 0.
`git diff --check` exits 0.
The source, build, and tests debug-marker grep exits 1 with no matches.
The final Worktree status is clean after the completion commit.
