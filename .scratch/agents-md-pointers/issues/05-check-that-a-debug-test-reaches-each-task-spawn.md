# Check that a Debug test reaches each task spawn

Status: needs-triage
Blocked by: none

## Problem

`diagnostics.concurrent` and `diagnostics.selectConcurrent` panic in a Debug build when a task argument holds a `Handle` with a slot. The check runs only in a Debug build, because a release panic would end a review over lost evidence. So a spawn that no test reaches has no check.

`CODING_STANDARDS.md` says that each new production task spawn has a Debug test that reaches it. The operator decided that this rule must be enforced, not only reviewed. The existing worker spawns in `drainPresentationCommands` in `src/tui/app.zig` have no such test today.

## Proposal

- Give each production spawn site a stable identity, for example its `@src()` at the call of `diagnostics.concurrent` or `diagnostics.selectConcurrent`.
- In a test build, record each site that a test reaches.
- Add a check that fails when a production spawn site has no record after the test run. `tools/check_task_spawns.py` already finds every production spawn, so it can supply the list of sites. Triage decides how the test run hands its records to the check, and whether `zig build test` can run the check after all test binaries.
- Add the missing tests for the existing spawns, first for `drainPresentationCommands`.
- When the check exists, move the rule from `CODING_STANDARDS.md` to `docs/rules/diagnostics.md` with its enforcement.

## Acceptance criteria

- [ ] A production spawn with no test that reaches it fails `zig build test`, and the message names the site and the fix.
- [ ] Each existing production spawn is reached by a Debug test, or it is named with its reason and an expiry date.
- [ ] The rule is a section in `docs/rules/diagnostics.md`, and `CODING_STANDARDS.md` no longer holds it.
- [ ] `zig build test` passes.

## Comments

### 2026-11-18 filed

The operator asked for this ticket and said that rules must be enforced.
