# Keep the session after a failed cache staging in the focus check

Status: ready-for-agent
Blocked by: none

## Problem

A failed cache staging in the focus check ends bbr. The behavior predates PR #36. A reviewer found it during the review of PR #36.

1. The event loop in `src/tui/app.zig` (lines 200 to 204) dispatches `ensure_focused_enrichment` after each event while a Review shows. It calls `try state.dispatch(.ensure_focused_enrichment)`, so an error from `dispatch` returns from the loop and ends the session.
2. `Presentation.dispatch` in `src/tui/presentation.zig` maps `.ensure_focused_enrichment` to `try self.ensureFocusedEnrichment()`.
3. `ensureFocusedEnrichment` calls `try self.queueCacheBuild(published, range.focused)` in two places. The first place is a pending cache update with a changed focus. The second place is a cache that `requiresCacheEnforcement` marks as over the budget.
4. `queueCacheBuild` returns `OutOfMemory` when `commands.ensureUnusedCapacity` or `createCacheBuild` fails. No record names the failure before the error returns.

A cache staging is maintenance. `stageReleasedSearchLeases` already catches its own `OutOfMemory`, records it once as `.buffer_build`, `.prepare`, sets `action_error` to `.out_of_memory` when no other message shows, and relies on the next focus check to stage again. The focus check has no such catch, so the same failure ends the session in one place and not in the other.

The test "M21 kernel cache focus failure preserves content and focus before retry" in `src/tui/presentation.zig` expects `error.OutOfMemory` from `dispatch(.ensure_focused_enrichment)`. `CODING_STANDARDS.md` says that a failed staging in the focus check returns `OutOfMemory` from `dispatch` and ends the event loop. Both describe the current behavior, so both change with the fix.

Related site to check: the active File path, `return self.queueFileEnrichment(published, file_index, false)`, also returns its `OutOfMemory` from the focus check.

## Proposal

Catch the `OutOfMemory` of `queueCacheBuild` in `ensureFocusedEnrichment`, as `stageReleasedSearchLeases` does. Record it once with `reportFailure(.buffer_build, .prepare, ...)` and return. The next focus check stages again, because the cache stays over the budget. Read `docs/rules/diagnostics.md` before the `catch`. The focus check also sets `action_error` to `.out_of_memory` only when no message shows, as `stageReleasedSearchLeases` does. The standard "A cache staging failure keeps the shown message" in `CODING_STANDARDS.md` already states that rule for a lease release, so both staging paths follow one rule.

## Acceptance criteria

- [ ] A test through the Presentation interface fails the cache staging in the focus check with a `FailingAllocator`. It expects `dispatch(.ensure_focused_enrichment)` to return without an error and one `report_diagnostic` record. The test fails before the fix.
- [ ] The same test expects `action_error == .out_of_memory` when no message showed before, and an earlier message of the same event to stay.
- [ ] The active File path (`queueFileEnrichment` in the focus check) is checked. If its `OutOfMemory` also ends the session for a maintenance step, the same fix covers it with its own red test. Otherwise the ticket comment says why it stays.
- [ ] The same test dispatches `ensure_focused_enrichment` again and expects the queued cache update.
- [ ] "M21 kernel cache focus failure preserves content and focus before retry" no longer expects `error.OutOfMemory`.
- [ ] `CODING_STANDARDS.md` no longer says that a failed staging ends the event loop.
- [ ] `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and `python3 tools/check_agent_docs.py` passes.

## Comments

### 2026-11-21 triage

The operator set the ticket to `ready-for-agent`. The open question is decided: the focus check shows `out_of_memory` only when no message shows, the same rule as a lease release. The active File path is in scope for a check, because it returns its `OutOfMemory` from the same focus check.

