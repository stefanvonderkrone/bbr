# Retry a failed Review Search source scan

Status: needs-triage
Blocked by: none

## Problem

Review Search scans the source of each File in a separate source scan. Two gaps on `main` lose the Occurrences of a File from the results. A reviewer found both during the review of PR #35.

1. A failed source scan does not queue its File again. `acceptReviewSourceScanned` in `src/tui/presentation.zig` marks the File unscanned and returns. It does not queue the next source scan, so the File and every later File wait until another event queues scans. The scan command also released the hold of the File, so the cache can evict its content in the meantime.
2. When `ScanReviewSource.create` fails in `maybeQueueReviewSourceScan`, the function returns. The hold of that File stays until the Overlay closes or the query changes. No source scan follows, and no record names the failure.

## Expected behavior

A failed source scan does not drop the Occurrences of its File without a message. A permanent failure, such as a lasting `OutOfMemory`, does not start an endless loop of scans. Each failure has exactly one record (see `docs/rules/diagnostics.md`).

## Acceptance criteria

- [ ] A test through the Presentation interface fails on `main` for gap 1 and passes after the fix.
- [ ] A test through the Presentation interface fails on `main` for gap 2 and passes after the fix.
- [ ] A File whose source scan fails gets a bounded number of further scans. The other Files keep their scans.
- [ ] A File that waits for a further scan keeps its hold. A File that gets no further scan releases its hold.
- [ ] The user sees a message when a File gives up.
- [ ] `docs/rules/tui-state.md` names the rule and its tests.
- [ ] `zig build test`, `zig fmt --check src build.zig tests`, and `python3 tools/check_agent_docs.py` pass.
