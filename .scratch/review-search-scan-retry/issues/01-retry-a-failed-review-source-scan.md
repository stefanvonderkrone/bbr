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

Follow-up, round 2. The user wants the cause of a scan that cannot start fixed, and a bounded pass under a lasting failure.

A source scan always starts now. `ScanReviewSource.create` copied the File into an arena, cloned the query, and grew the command queue, so each step could fail with `OutOfMemory`. The command now retains the published Session and reads its File there, retains a reference-counted `SharedQuery` that Presentation allocates once for each query change, and waits in its own slot, `Presentation.queued_source_scan`. Reserved capacity in the command queue does not work, because every other command takes the spare capacity before it appends. The give-up path for a scan that cannot start, its record, and the `source_scan_allocator` test seam are gone. Red test: "M21 kernel Review Search starts a source scan when no allocation succeeds".

A second failed scan now stops the pass. The retry runs in the next source scan, not after every unscanned File. Each File without a successful scan becomes `given_up`, has no hold, and takes no new hold until a new query or a reopened Overlay. A lasting failure costs two scans and two worker records, one for each failed scan, because `docs/adr/0014` records each failure once. Red test: "M21 kernel Review Search stops its source scans after it gives up on a File".

The scan result takes its own Session reference, so the Presentation thread releases the last reference of a replaced Session. `SharedQuery` lives in `std.heap.page_allocator`, because a worker can release it last.

Commits: `62e3d445` (red A), `1258e1cd` (fix A), `3ed40bc1` (red B), `2e8ab1e7` (fix B), `e3d4234e` (review fix: thread ownership).

Checks: `zig build test` exit 0. `zig fmt --check src build.zig tests` passes. `python3 tools/check_agent_docs.py` passes.

Open point: a lasting failure writes two records, not one, because each failed scan has its own record.

Follow-up, round 3. CodeRabbit posted five comments on PR #36. Each one holds.

Enforcement claim (4634097592). The return type of `ScanReviewSource.create` stops nothing, because a `catch` compiles. An allocation from the Presentation allocator with a `catch`, in `maybeQueueReviewSourceScan` or in `create`, fails the test "M21 kernel Review Search starts a source scan when no allocation succeeds". An allocation from `std.heap.page_allocator` passes it. The rule now names the test, and `CODING_STANDARDS.md` holds the gap. This was the fifth Enforcement paragraph that claimed more than its check. A separate PR on branch `enforcement-compile-claim-lint` adds a check that rejects a new compile-error claim that names no mechanism that fails.

Reserved slot (4634097620). The query edit inserted its scan into a full queue after the discarded source scan staged a cache build. The query scan now takes the reserved slot before the discard of the source scan. A discarded scan also holds its File again, so the edit stages no cache build.

Shown message (4634097636). A cache staging failure now shows `out_of_memory` only when no message shows, because the next lease release stages again.

Rollback (4634097649). The reset of the source pass, the holds, and the new acquisition now run when the results of the query publish. A source scan without a result returns its File to the state and hold before the scan. A rollback resumes the restored pass.

Stale hold (4634097603). After the rollback fix, a given-up state clears only with a new batch, which already retries a build. A first query or an Overlay change still changes the hold decision without a Storage change. Admission now retries a build whose recorded hold differs and takes the recorded hold.

Commits: `5b31dda7`, `c26229e1` (red), `c39ac446`, `81787495`, `6ac7b91a`, `96d5075a` (red), `6c0379bf`, `fd4b29c4`, `814612aa` (red), `2ab56ef0`.

Checks: `zig build test` exit 0. `zig fmt --check src build.zig tests` passes. `python3 tools/check_agent_docs.py` passes.

Follow-up, round 4. CodeRabbit posted three comments on PR #36. Each one holds.

Cache staging at the scan start (4635473845). The start of a source scan released the Review Search hold of its File through the lease release that stages a cache build. The scan takes its own lease first, so the release freed nothing, but the staging ran when a cache update was pending. Opening Review Search while a cache build ran on the worker queued a second build and made the first result stale. The start now drops the hold without a staging, and the completion of the scan stages as before. The enforcement sentence also claimed that the allocation test fails on an allocation behind any `catch`. An allocation whose failure the start ignores passes it, so the sentence now names only a failed allocation that stops the start.

Scans before the first results (4635473853). A first query that rolled back kept the query without results and still started a source scan, and each result failed to publish until the pass gave up. The source scans now wait for published results.

Rollback test (4635473862). The test now checks that File 0 resumes as a retry.

Commits: `75421ffa`, `d078c143` (red), `46bd4d03`, `b33bbd67` (red), `c4735972`, `6e4e68d8`, `43b6a502` (a test that results without a match start the source scans).

Checks: `zig build test` exit 0. `zig fmt --check src build.zig tests` passes. `python3 tools/check_agent_docs.py` passes.

Follow-up, round 5. CodeRabbit posted two comments on PR #36.

Cache staging after a stopped pass (4644422867). The behavior holds, but the rule named the wrong mechanism. No lease release follows a pass that stops. The event loop in `src/tui/app.zig` dispatches `ensure_focused_enrichment` after each event while a Review shows, and `ensureFocusedEnrichment` stages the cache build while the cache is over the budget, also while Review Search is open. The staging test now releases File 11, which is outside the focus, and checks that the focus check after the failure queues the cache update. When the check stops staging, the test fails. A staging failure in the focus check returns `OutOfMemory` from `dispatch` and ends the event loop. This was already the behavior, and the rule now says so.

Source scan of a reopened query (4644422882). The comment holds. A query edit that the Overlay closed before its results published keeps the batch of `rollback_query`. When the reopen could not queue the query scan, a source scan of the new query started and merged into the old batch. `ReviewSearchState.currentQueryResultsPublished` now states that the batch holds the results of the current query, and the start and the merge of a source result both use it. A published batch without a match stays eligible. This is the second case of a source scan that starts against a batch of another query, so one predicate now decides both cases.

Open point: after a failed reopen, the Overlay shows the new query over the results of the previous query, without a pending state, until the next edit or reopen.

Commits: `9e19335e` (red), `ee5d3a7d`, `21eb2fbf`, and a docs commit that states the pending update and the failure of the focus check.

Checks: `zig build test` exit 0. `zig fmt --check src build.zig tests` passes. `python3 tools/check_agent_docs.py` passes.

Follow-up, round 6. The user decided the open point of round 5.

Rollback of a reopened query. When the reopen cannot queue the query scan, `openReviewSearch` now rolls the query back through `rollbackReviewSearchQuery`, as a failed query edit does. The Overlay shows the query of its results, keeps the out-of-memory message, and records the failure once. The rollback also resumes the source pass of that query. The test "M21 kernel Review Search rolls back a reopened query whose scan cannot queue" replaces the test of round 5 for this path. A new test, "M21 kernel Review Search starts no source scan while a query edit is pending", keeps a check on `currentQueryResultsPublished`. The mutation `batch != null` fails that test.

The failed cache staging in the focus check that ends bbr is a separate effort: [01-keep-the-session-after-a-failed-focus-check-staging.md](../../focus-check-staging-failure/issues/01-keep-the-session-after-a-failed-focus-check-staging.md).

Commits: `1730bf39` (red), `5914bf57`.

Follow-up, round 7. The user rejected the rollback of round 6, because the typed text left the input without a user action.

Retry of a reopened query. When the reopen cannot queue the query scan, the edited query stays in the input and the Overlay stays pending over the results of the previous query, as during a query edit. `needs_scan` stays set. The `ensure_focused_enrichment` input, which the App dispatches after each event while a Review shows, queues the query scan again when the open Overlay is pending with `needs_scan`. A lasting `OutOfMemory` retries only at a later dispatch of that input, never in a loop. The App dispatches it once after each event and once more after a geometry change. Each failed attempt records one failure and shows the out-of-memory message. `rollback_query` stays set while the query is pending, so `currentQueryResultsPublished` starts no source scan. The test "M21 kernel Review Search retries a reopened query scan that cannot queue at the next event" replaces the rollback test of round 6. The test "M21 kernel Review Search starts no source scan while a query edit is pending" stays.

Commits: `2c464d66` (red), `001955e2`, and a review follow-up that moves the retry guard into `retryReviewSearchQuery`.

Follow-up, round 8. A successful retry cleared the action error, also a message that an earlier input of the same event set. The user decided that the retry clears only the out-of-memory message of the failed scan. `retryReviewSearchQuery` keeps the message shown before the retry, unless the retry succeeds and that message is the out-of-memory message. `failReplacement` uses the same check for the message that it owns. Another out-of-memory message of the same event looks the same, so the retry clears it too. The test "M21 kernel Review Search keeps another message of the same event when a reopened query retry succeeds" checks an invalid query message. The test "M21 kernel Review Search retries a reopened query scan that cannot queue at the next event" now checks that the retry clears the out-of-memory message before the results publish.

Commits: `9375d315` (red), and the fix on top.
