# Fix the Open Code Review findings of PR #45

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure
Blocked by: none

Source: Open Code Review of PR #45.

## Problem

1. A failed `.cache_update` build in `acceptBufferDisclosure` shows `buffer_build_failed` over a shown message.
   A cache update is maintenance work, so it must keep the shown message.
   The `job.failed` branch shows the message for every kind except `.enrichment` without the check of a shown message.
2. `CODING_STANDARDS.md` says that maintenance work records its cause once.
   `acceptBufferDisclosure` writes no record for a failed build, and no rule says where the one record comes from.
3. `literal_origin_violations` in `tools/check_action_errors.py` returns no violation when it finds no `pub const Presentation = struct {` line.
   Then the check passes but reads nothing.
4. `docs/rules/tui-state.md` says that the checker rejects a qualified origin such as `ErrorOrigin.user`.
   No test covers that claim.

## Proposal

1. Check each build kind in the `job.failed` branch against the two rules.
   A failed build of maintenance work shows its message only when no message shows.
2. Find the layer that records a failed build.
   If a layer records it, name that layer in the rule and add no second record.
   Otherwise, record the failure once in Presentation.
3. Make the checker fail with a clear message when it finds no Presentation struct.
4. Add a test for a qualified origin. Fix the checker if the test fails.

## Acceptance criteria

- [ ] A test fails before each fix, or a mutation proves that a new test pins the current behavior.
- [ ] A failed cache update build keeps a shown message and shows `buffer_build_failed` when no message shows.
- [ ] Each other build kind of the `job.failed` branch follows its rule.
- [ ] A failed build has exactly one record, and the rule names its source.
- [ ] The checker fails when it finds no Presentation struct.
- [ ] A test covers the rejection of a qualified origin.
- [ ] Each rule is stated once in the docs.
- [ ] The unit tests, format check, agent document check, action error check, diagnostics check, and doc symbol check pass.
- [ ] No debug instrumentation remains, and the Worktree is clean.
