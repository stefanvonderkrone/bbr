# Retry a failed Review Search source scan

Status: resolved
Blocked by: none

## Problem

Review Search scans the source of each File in a separate source scan. Two gaps on `main` lose the Occurrences of a File from the results. A reviewer found both during the review of PR #35.

1. A failed source scan does not queue its File again. `acceptReviewSourceScanned` in `src/tui/presentation.zig` marks the File unscanned and returns. It does not queue the next source scan, so the File and every later File wait until another event queues scans. The scan command also released the hold of the File, so the cache can evict its content in the meantime.
2. When `ScanReviewSource.create` fails in `maybeQueueReviewSourceScan`, the function returns. The hold of that File stays until the Overlay closes or the query changes. No source scan follows, and no record names the failure.

## Expected behavior

A failed source scan does not drop the Occurrences of its File without a message. A permanent failure, such as a lasting `OutOfMemory`, does not start an endless loop of scans. Each failure has exactly one record (see `docs/rules/diagnostics.md`).

## Acceptance criteria

- [x] A test through the Presentation interface fails on `main` for gap 1 and passes after the fix.
- [x] A test through the Presentation interface fails on `main` for gap 2 and passes after the fix.
- [x] A File whose source scan fails gets a bounded number of further scans. The other Files keep their scans.
- [x] A File that waits for a further scan keeps its hold. A File that gets no further scan releases its hold.
- [x] The user sees a message when a File gives up.
- [x] `docs/rules/tui-state.md` names the rule and its tests.
- [x] `zig build test`, `zig fmt --check src build.zig tests`, and `python3 tools/check_agent_docs.py` pass.

## Completion

Causes. A failed worker scan and a failed publication marked the File unscanned and returned before `maybeQueueReviewSourceScan`, so the source scans stopped. The command had taken over the hold of the File, so its release left the File unheld. A failed `ScanReviewSource.create` returned with only a message, kept the hold, and made no record. Four of the five publication allocation failures made no record either.

Change. Each File has a `SourceScan` state for the query. A failed worker scan or publication holds the File again before the command releases its lease, and the File scans again after every unscanned File. A second failure gives up on the File, releases its hold, and shows `buffer_search_scan_failed`. A command that cannot start gives up on its File at once with one record, because no later completion would run a deferred retry. A new query or a reopened Overlay scans a given-up File again. The command clones the validated query, so `OutOfMemory` is its only error.

Commits: `1eeb3a42` (allocator seam), `30ea5375` (red tests), `bd0b9161` (fix and rule).

Checks: `zig build test` exit 0. `zig fmt --check src build.zig tests` passes. `python3 tools/check_agent_docs.py` passes.

Review: the standards and spec reviews found no defect. The review fixes are the rule spacing, the state names `awaiting_retry` and `given_up`, one hold release helper, and record counts in the worker failure tests.

## Comments

Resolved. Open point: a scan command that cannot start now shows "Review Search failed" instead of "Out of memory". The record keeps the cause.
