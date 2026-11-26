# Fix the Open Code Review findings of PR #45

Status: resolved
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

- [x] A test fails before each fix, or a mutation proves that a new test pins the current behavior.
- [x] A failed cache update build keeps a shown message and shows `buffer_build_failed` when no message shows.
- [x] Each other build kind of the `job.failed` branch follows its rule.
- [x] A failed build has exactly one record, and the rule names its source.
- [x] The checker fails when it finds no Presentation struct.
- [x] A test covers the rejection of a qualified origin.
- [x] Each rule is stated once in the docs.
- [x] The unit tests, format check, agent document check, action error check, diagnostics check, and doc symbol check pass.
- [x] No debug instrumentation remains, and the Worktree is clean.

## Comments

### 2026-11-26 evidence

1. Red: "Review recovery a failed cache update keeps the shown message" failed with `expected .picker_load_failed, found .buffer_build_failed`.
   The other build kinds of the `job.failed` branch come from user input, so they still show their failure.
   A mutation that maps `.enrichment` to false in `isMaintenance` fails "M21 kernel a failed enrichment rebuild keeps a shown message and reports only demanded Files".
2. The record exists already. `recordFailures` in `src/tui/presentation_runtime.zig` records the `evidence` of the build, through `deliver` or the command drain in `src/tui/app.zig`.
   The new test "diagnostics a failed Buffer build has one record from the worker boundary" passes on the old code.
   It fails when `recordFailures` skips the build, and when Presentation writes a second record.
   The test "M21 kernel failed enrichment build that cancels a Refresh location shows its failure" asserts the right behavior, so it stays unchanged.
3. Red: `test_a_file_without_the_presentation_struct_is_rejected` failed with `AssertionError: 0 != 1 : []`.
   The multiline helper fixture had no struct line, so it now wraps its methods in the struct.
4. The checker already rejected `ErrorOrigin.user`, so `test_a_qualified_origin_is_rejected` passes.
   A pattern that accepts a qualified name before the dot fails it.

## Completion

Commits `ad8a3eba..0d7f7332`.
The checks are `zig build test` (68/68 steps, 1770/1770 tests, exit 0), `zig fmt --check src build.zig tests`, and `check_agent_docs.py`, `check_action_errors.py`, `check_diagnostics.py`, and `check_doc_symbols.py`.
All of them pass.
The Standards and Spec reviews found no code defect.
Their doc findings are fixed in `0d7f7332`. The record rule moved to `docs/rules/diagnostics.md` and names the launch failure path.
