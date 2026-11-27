# TUI state rules

This document holds the checked rules for Presentation, Sessions, Buffer and Frame builds, search, navigation, and Overlays in `src/tui/`.
The parts that no check covers are in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

## Resize and Composer footer

A terminal resize invalidates the painted revision, also when the size does not change.
A closed Composer keeps no footer message.

Enforcement: the test "External Edit footer ends with its Composer and appears after another accepted edit" in `src/tui/presentation.zig`, run by `zig build test`. `tests/external_edit_ci_test.py` checks a Neovim return without input and a Composer save and cancel in CI.

## Buffer rebuild storage

A Buffer build appends its rows to a list in the result allocator.
It reserves the list once from `rowCapacity` in `src/tui/buffer.zig`.
It returns the list with `toOwnedSlice`, not with a `dupe`.
`BuildOptions.scratch_allocator` holds only ReviewCard projection scratch.
A rebuild list or map whose size is known before its loop reserves that size first.
Examples are the visual rows in `frame.buildVisualRowsWithOptions` and the `owners` map in `NavigationIndex.build`.
A rebuild map from a key to a list of entries is a `KeyLists` in `src/tui/key_lists.zig`, not a map with one list for each key.
`KeyLists.build` counts the entries of each key first, so all lists share one entry array and no list grows.
`NavigationIndex.spans`, `SearchProjection.source_rows`, and `SearchProjection.body_rows` use it.
A reservation is a hint, never a limit.

Enforcement: the allocation tests in `src/tui/buffer.zig`, `src/tui/frame.zig`, and `src/tui/key_lists.zig`, run by `zig build test`. The Buffer build test passes `std.testing.failing_allocator` as scratch storage. The tests that grow past a capacity hint are in `src/tui/frame.zig` and `src/tui/presentation.zig`.

## Rebuild index entries

An index that each rebuild fills holds only the entries that a named reader asks for.
Before you add entries to such an index, name the code that reads them.
`NavigationIndex.owners` holds no Line owner.
`find` resolves a Line through `spans`, and every other `owners` reader asks for a ReviewCard header, a Draft header, a disclosure, or another owner that is not a Line.

Enforcement: the `NavigationIndex` tests in `src/tui/frame.zig`, run by `zig build test`, check that Line rows add no `owners` entry. The test "search projection lookups match the 6f9f09f baseline in both Layouts" in `src/tui/presentation.zig` pins every `owners` lookup in the form that its readers use.

## List Overlay arm pointers

A List Overlay arm holds no pointer except the buffers that it owns.
Borrowed data, such as the Session's Files, comes in as an argument at each call.

Enforcement: the `comptime` block after `ListOverlay` in `src/tui/list_overlay.zig` (compile error).

## List Overlays close before Session replacement

The File Finder and the Command Palette close before a Session replacement.

Enforcement: the exhaustive switch in `ListOverlay.closesOnReplacement` in `src/tui/list_overlay.zig` (compile error for a new arm). The tests "File finder opened during a replacement does not outlive the replaced Session" and "a Session replacement closes the Command Palette" in `src/tui/presentation.zig`, run by `zig build test`.

## Submission Overlay ownership

Escape and ctrl-c close the Submission Overlay without ending its SubmissionRun or releasing its ownership.
Submitting Drafts stay readable across Frame rebuilds.
Enter navigates by Draft identity or posted Comment identity.
Navigation never permits a mutation that Submission owns.
Closing a clean result permits later batches, but it does not authorize unrelated retries.

Enforcement: the `Review recovery` tests in `src/tui/presentation.zig`, run by `zig build test-review-recovery` and `zig build test`. They check active, paused, and terminal input, retained ownership, repeated batches, and posted Comment navigation.

## Background work keeps an unrelated action error

Each shown action error records its origin, the path that showed it.
`Presentation.action_error` holds a `ShownError`, which pairs the `ActionError` with an `ErrorOrigin` and an optional PullRequest key.
The key is an `OwnedRemoteReviewIdentity`, because only a Remote Review has a `repo#id` name.
Code writes it only through `showErrorFor` and `clearError`, and neither takes an origin.
Each change of the shown error also changes `status_revision`, because the App paints only after a change of `Projection.revision`, and the `ensure_focused_enrichment` input changes no other revision.
`showError` calls `showErrorFor` without a key.
A Submission, a Comment edit, a Comment delete, and a Reviewer Verdict can finish after the user opens another PullRequest.
Their work shows each error of their own PullRequest with `showErrorFor` and the key of that PullRequest.
An `out_of_memory` error has no key, because it belongs to the process and not to one PullRequest.
When that PullRequest is not the visible review, or no review is visible, the status names it as `repo#id: ` before the error text.
The re-anchor banner shows no action error of another PullRequest, because its text names no PullRequest.
While Buffer Search is open, the status shows the Buffer Search line with only Buffer Search errors, so it does not show an action error of another PullRequest.
An accepted Buffer Search shows `buffer_search_no_matches` when its batch has no occurrence, so the user sees why nothing opened. Without a batch, the accept keeps only `buffer_search_scan_failed` or `buffer_search_no_matches`. These messages say why nothing opened. The accept clears any other message by the rule of `clearError`. So an accept by the Enter key clears any other message. An accept that a completion runs clears only a message of the origin of that completion.
While a scan of an edited query is pending, the input shows the batch of the previous query. A scan that ends without its own batch drops that batch with `BufferSearchInput.failPendingScan`. So the batch of an accept always belongs to the accepted query.
An Enter key during pending work of the input sets `accept_when_ready`. The landing of the result then runs the accept. Each failure that ends the work without a restore build runs the accept in `failPendingInput`. The accept runs before the failure shows its message, so the accept keeps that message. The accept of a cleared query can queue the build of the next accepted occurrence. That build also restores the disclosures that the failed clear kept. When it lands, its result replaces the message of the failure. When that build cannot queue, the view keeps the disclosures of the preview, and `out_of_memory` shows. A failed opening runs no accept, because an accept would queue the failing opening again. The failed opening keeps the input open. A second Enter key retries the opening.
A failed scan ends through `failBufferSearchScan`. Like a scan without matches, it queues the input build that restores the disclosures from before the search preview. That build shows `buffer_search_scan_failed` again. When that build cannot queue or fails, the view keeps the disclosures of the previous preview and `saved_disclosures`. The message of that failure then replaces `buffer_search_scan_failed`.
`showErrorFor` and `clearError` read `Presentation.event_origin`, the origin of the event that runs.
`dispatch` sets the event origin from `OwnedInput.errorOrigin` and restores it when the event ends.
A key, a mouse action, or an Overlay action has the origin `.user`, and its `clearError` clears any error.
An event is one `dispatch`, or an outermost `withErrorOrigin` outside `dispatch`.
A failed step of maintenance work does not show its message at once.
`showMaintenanceError` records the failure in `Presentation.maintenance_failures`, which holds one entry for each `MaintenanceStep` tag.
`settleMaintenance` removes the entry of a step when a later run of that step in the same event succeeds.
So a cache staging that a later staging of the same event recovers shows no message.
The File Enrichment step names its File, so only a later queue of the same File recovers it. After a failure of a second File in the event, the step names no File, and no queue recovers it.
When the event ends, `finishEvent` shows the failure of the first step in `MaintenanceStep` order. It shows that failure with the origin of that step, and only when no message shows.
Then it empties the record.
So no clear of the event removes the message of a failed maintenance step. The order of a clear and the steps of its event does not matter.
`acceptPreparedSession` discards the queued searches after the new Session publishes. So a discard stages no cache build for the replaced Session.
A completion of background work has the origin of its own path, and its `clearError` clears only an error of that origin.
Thus a completion keeps an error that another path showed and that the user has not read yet.
A helper that keys and completions both reach takes the origin of the event that reaches it.
A Buffer build completion takes its origin from `DisclosureBuild.Kind.errorOrigin`.
Draft save and Draft mutation builds have the origin `.draft`, separate from view builds.
Buffer Search scans and search disclosure builds use `.buffer_search`.
Review Search scans use `.review_search`.
An input that shows and clears no action error has no origin.

Some work runs inside an event but belongs to another path.
It names its origin as an enum literal through `withErrorOrigin`, which restores the origin of the event after the work.
These overrides exist:

- `dispatch` runs `holdReviewSearchPreview` after each event as `.review_search`, because the Preview hold acquires Files for Review Search.
- The focus check and `openReviewSearch` run `retryReviewSearchQuery` as `.review_search`, so a successful retry clears only a Review Search error.
- `pumpReviewSearchAcquisition` queues each File as `.review_search`, because it acquires Files for Review Search. So a success keeps an error of another path, such as `file_enrichment_launch_failed` of the File that failed before.
- `applySubmissionTreeKey` shows `replacement_pending` as `.reconciliation`, so the end of the replacement clears the notice.
- `init` runs `discoverRecovery` as `.submission`, because recovery belongs to the Submission path.
- After an allocation failure, `takeCommand` runs `requestShutdown` as `.submission`, because shutdown resumes a paused Submission.

Outside `dispatch` and `withErrorOrigin` the event origin is null.
Then `showErrorFor` panics, because no event names the origin.
`clearError` returns early when no error shows.
Outside an event, `clearError` panics only while an error shows.
A test that calls a method directly runs it through a test helper such as `showTestError`, which calls `withErrorOrigin`.
The File Enrichment path includes enrichment builds, cache updates, and the focus check that starts a File Enrichment.
A speculative enrichment shows and clears no action error.
The Projection gives the `ActionError` as `action_error` and the PullRequest key as `action_error_key`.

Enforcement: exhaustive switches in `OwnedInput.errorOrigin` and `DisclosureBuild.Kind.errorOrigin` reject a new input or build kind without an origin at compile time. Both switches are in `src/tui/presentation.zig`. `tools/check_action_errors.py` and `tests/check_action_errors_test.py` run under `zig build test`. The checker fails on a write of `action_error` outside `showErrorFor`, `clearError`, and `finishEvent`, such as `self.action_error = null` in a completion. It also fails on a write of `event_origin` outside `dispatch` and `withErrorOrigin`, and it names `withErrorOrigin` as the fix. It fails on a `withErrorOrigin` call in `Presentation` whose origin is not an enum literal. An example is the copied `kept.origin` of the old query retry. The error names `failMaintenance` as the way to keep a shown error. Outside the test blocks, it fails on a read of `action_error`, also in a free function. The check allows a read only in the three writers, `clearErrorExcept`, and `projection`. Outside the `Presentation` body, a read through `projection().action_error` passes. One failing read is the old keep `self.action_error == null` of `failMaintenance`. Another is the copy `const shown = self.action_error` of the old query retry. A read with `!=`, with the operands swapped, through `orelse`, an `if` capture, an alias, or a pointer fails too. The error names `failMaintenance` and `showMaintenanceError` as the fix. It also fails on a use of `maintenance_failures` outside `settleMaintenance`, `showMaintenanceError`, and `finishEvent`. Each rule reads the code text joined across lines, so a line break inside an access does not hide it. The write rules read the whole file. The read rules read the whole file outside the test blocks. Only a method of `Presentation` counts as a helper. The `withErrorOrigin` rule reads only the `Presentation` struct body. So it does not check free functions or `withErrorOrigin` used as a value. It fails when it finds no line `pub const Presentation = struct {`, so a rename of the struct cannot make it read nothing. It also rejects a qualified origin such as `ErrorOrigin.user`. Outside the test blocks, a pointer such as `&self.action_error` is a read, so it fails. In a test block, the checker does not see a write of `action_error` through a pointer. An example is `slot.* = null` after `const slot = &state.action_error` in a test. It does not see a write of `event_origin` through a pointer anywhere. It also does not see `@field` with a field name in a string. The `Review recovery` tests in `src/tui/presentation.zig` check four results. Each completion keeps an unrelated action error. The Submission, a Comment delete, and a cache update still clear an error of their own origin. A view build keeps a Draft error and the error of a failed Draft jump. A user retry of a Submission or of a recovery clears an unrelated error. The test "M21 kernel the paint revision changes when a focus check shows or clears a message" fails when a shown or cleared error keeps the revision. The test "M21 kernel Review Search acquisition queue keeps the shown message" fails when the acquisition clears the error of the event that pumps. "M21 kernel opening a Review Search hit in an evicted File clears an older message" fails when the user opening keeps the older message. "M21 kernel opening Review Search shows the failure of its acquisition queue" fails when the open clears the message of its own pump, also after a reopened query retry. "M21 kernel a Review Search query edit shows the failure of its cache staging" and "M21 kernel a Review Search destination shows the failure of its cache staging" fail when a clear after a lease release removes the message of its failed staging. They also check this when an older message shows before the event. "M21 kernel a successful acquisition pump keeps the failure of the Review Search query retry before it" fails when the pump of an opened Review Search clears the message of a retry that failed one allocation. It also fails when the pump of the focus check does so. "M21 kernel a Review Search query edit shows no failure of a cache staging that a later staging recovers" fails when a recovered staging keeps its message. "M21 kernel a recovered cache staging keeps the failure of another maintenance step" fails when the recovery also removes the failure of another step. "M21 kernel a Session replacement shows no cache staging failure of the replaced Session" fails when a discard of the replacement stages a cache build for the replaced Session. "M21 kernel an accepted Buffer Search without matches keeps its message" fails when an accept clears `buffer_search_no_matches`. "M21 kernel an accepted Buffer Search shows no-match only for an empty batch" fails when an accept shows it for a batch with matches or over a failed scan. "M21 kernel an accepted Buffer Search without a batch keeps only a message of the search" fails when an accept without a batch keeps an unrelated message or clears the message of its failed scan. "M21 kernel an accepted Buffer Search keeps the scan failure of its query edit" fails when a failed scan of an edited query keeps the batch of the previous query. With that batch, the accept shows `buffer_search_no_matches` or clears `buffer_search_scan_failed`. "M21 kernel a failed Buffer Search scan collapses the preview of the previous query" fails when a failed scan keeps a Resolved Thread that the previous preview expanded. It also fails when a completed scan without ranges keeps one. "M21 kernel a Buffer Search input that fails after a query edit opens no occurrence of the previous query" checks a failed disclosure queue and a failed input build. It also checks a failed admission of an input build and a failed queue of a stale scan. It fails when one of these failures keeps the batch of the previous query. It also fails when one of them leaves the input open after an Enter key during the failed work. "M21 kernel an Enter key during a failed Buffer Search scan closes the input" fails when a failed scan without a restore leaves the input open after an Enter key during the scan. It also fails when a failed restore does the same. "M21 kernel an Enter key during a failed Buffer Search query clear closes the input" fails when a failed query clear or a failed queue of its retry does the same. "M21 kernel an Enter key during a failed Buffer Search query clear opens the next accepted occurrence" fails when that Enter key with an accepted search leaves the input open or opens no occurrence. "M21 kernel a failed Buffer Search opening keeps the input open" fails when a failed opening build or a failed queue of its retry leaves the input pending. It also fails when either failure queues the opening again. It also fails when a second Enter key does not retry the opening. "M21 kernel a query edit drops the restore of a failed Buffer Search scan" fails when a restore that is queued or running at a query edit lands or shows its message. "M21 kernel a failed restore of a failed Buffer Search scan shows the build failure" fails when a failed restore keeps `buffer_search_scan_failed`. The helper `completeTestDisclosureBuilds` fails on a queued scan. So a test cannot pass a build that queues a scan without a run of that scan. "M21 kernel a File Enrichment queue recovers only the failure of its own File" fails when a queue of the failed File keeps its failure. It also fails when a queue of another File removes that failure. It also fails when a queue of one of two failed Files removes the failure of the other. `zig build test` runs them. The tests "Reviewer Verdict error after a Session switch names its PullRequest", "Review recovery a Comment edit or delete failure after a Session switch names its PullRequest", and "Review recovery a Submission failure after a Session switch names its PullRequest" in `src/tui/presentation.zig` check the key of the error after the user opens another PullRequest. The test "an action error of another PullRequest names that PullRequest" in `src/tui/app.zig` checks the `repo#id: ` status text. It also checks that an error without a key keeps the plain text. The test "a re-anchor banner shows no action error of another PullRequest" in the same file checks the banner.

## Reading location across Refresh and Reconciliation

Refresh and Reconciliation of the same Review restore the reading location through semantic identity.
They use no pointers or File indexes from the previous Session.
Preferences and restoration use one side-aware File lookup.
File Tree markers follow the restored active File.
A missing location falls back to its File header.
A missing File keeps the initial navigation reset.
Search and Selection still expire.

Enforcement: the `Review recovery` tests and the same-Review acceptance test in `src/tui/presentation.zig`, run by `zig build test`. `tests/reload_location_ci_test.py` checks the location retention and the missing-File reset through the real TUI in CI. Its Git commands use a private home with no identity and with signing enabled, so the fixture supplies its own identity and disables signing.

## Published Session content

A published Session never changes its Diff, its Threads, or its mention names.
A change makes a new Session with a new Session Epoch through Refresh or Reconciliation.
The Buffer Search candidate key covers these inputs only by identity and the Session Epoch.
A worker that retains the Session reads them while the Presentation thread owns it.
The types of the Session fields that hold them reach no mutable pointer, so no code writes their contents through those fields.
A `*const` pointer alone does not give this: `getPtr` of a `std` hash map takes the map by value and returns a mutable `*V`, and its iterators give entries that hold one.
So `Session.mention_names` points to a `std.StaticStringMap`, whose storage and accessors are `const`.

Enforcement: the `comptime` block after `Session` in `src/tui/session.zig` calls `read_only.assert` from `src/tui/read_only.zig` on `diff`, `threads`, and `mention_names` (compile error in every build). The assertion follows fields, elements, function pointers, and the return types of public non-generic functions, and it names the first mutable pointer. It does not follow a generic function, and it does not stop a reassignment of a field, such as `session.diff.files = &.{}`, through a mutable `*Session`. [The coding standard](../../CODING_STANDARDS.md#no-change-to-a-published-session) covers that part. `tests/read_only_test.py`, run by `zig build test`, compiles a write through `*const MentionNames`, such as `getPtr(id).?.* = label`, and expects a compile error. It also expects `read_only.assert` to reject each kind of mutable pointer, the old `*const std.StringHashMapUnmanaged` included. The search candidate key in `src/tui/buffer.zig` sees a field reassignment through the new address. The assertion does not stop a field reassignment, a write through `@constCast`, or a write through a mutable alias that the producer keeps. [No change to a published Session](../../CODING_STANDARDS.md#no-change-to-a-published-session) covers those writes.

## New List Overlay

A new List Overlay is one arm of the `ListOverlay` union in `src/tui/list_overlay.zig`.

Enforcement: the exhaustive switches in the `ListOverlay` methods (compile error).

## OwnedCommand launch failure

An `OwnedCommand` converts to its launch-failure `OwnedInput` only in `OwnedCommand.launchFailed` in `src/tui/presentation.zig`.
No arm frees its payload.

Enforcement: the exhaustive switch in `OwnedCommand.launchFailed` (compile error). The test "every OwnedCommand launch failure keeps its correlation and frees the command" in `src/tui/presentation.zig`, run by `zig build test`.

## Questions about one File

A question about one File reads the rows that the Buffer records for that File in `FileRow`.
It does not read every Buffer row or visual row with a `fileIndexForRow` search for each row.
`buildWithComments` in `src/tui/buffer.zig` fills `FileRow`.
`Buffer.fileHeaderRow` gives the File header, and `Buffer.statusPlaceholders` gives the status placeholder rows.
A new per-File fact is a new `FileRow` field that the build sets.
`FileRow.status_placeholders` has no default, so a new Buffer builder must set it.
A build that must visit every row walks the `file_rows` boundaries in order.
The old `selectedVersionUnavailableForFile` scanned all rows on each event while the cursor was on a File header.
That scan cost about 47 ms of Presentation thread CPU for each key (ticket 26).

Enforcement: `tools/check_row_scans.py` with `tools/row_scan_baseline.txt`, run by `zig build test`. A removed loop fails until `python3 tools/check_row_scans.py --write-baseline` lowers the baseline. The baseline keeps two worker search loops until [ticket 28](../../.scratch/enrichment-rebuild-follow-up/issues/08-ask-the-buffer-about-one-file-in-the-worker-searches.md) removes them.

## Help Overlay sections

The help Overlay lists every Keymap Action in the section that `keymap.helpSection` names.
Some Overlays read keys outside the Keymap, such as the Submission Overlay, the delete confirmation, and the help itself.
Their fixed keys are in `help.fixed_sections` in `src/tui/help.zig`.

Enforcement: the exhaustive switch in `keymap.helpSection` (compile error for a new Action).

## Help Overlay Snapshot

The help Overlay owns each query, filtered line array, and scroll in one complete Snapshot.
A failed replacement keeps the current Snapshot and its cancellation target.
Acceptance and cancellation allocate nothing.
Rendering and scroll geometry use the same filtered lines.

Enforcement: the `help` tests in `src/tui/help.zig`, and the test "help search paints rounded input boxes query and no matches from the same lines" in `src/tui/render.zig`, run by `zig build test`.

## File Jump

A File Jump calls `Published.jumpToFileHeader` in `src/tui/presentation.zig`.
It puts the File header on the top DiffPane row, and Nav clamps the scroll at the end of the Buffer.
A File Jump from the File Tree moves focus to the DiffPane.

Enforcement: the test "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" in `src/tui/presentation.zig`, run by `zig build test`.

## File Tree cursor follows the active File

While the DiffPane has focus, the File Tree cursor follows the active File.
`revealActiveFile` moves it.
Keyboard, mouse, and view-build paths all call `revealActiveFile` when the active File changes.

Enforcement: the tests "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" and "M21 kernel active File reveal without collapsed ancestors needs no allocation or Buffer rebuild" in `src/tui/presentation.zig`, run by `zig build test`.

## ReviewCard geometry and rails

The Buffer owns the shared ReviewCard geometry and rail nodes.
Active Path lookup follows parent links and indexes roles by depth.
Each rail chain has one node for each distinct column.
The shallowest rail owns a column when the indentation reaches its limit.

Enforcement: the ReviewCard rail, Active Path, and ReviewCard metadata tests in `src/tui/buffer.zig`, and the test "sibling rails use the Active Path role past more than one sibling" in `src/tui/render.zig`, run by `zig build test`.

## Search range projection

Production code gets Review Search ranges and Buffer Search ranges from the retained `SearchProjection` of the current visual rows.
It never projects every visual row.
It calls `SearchProjection.project`, `SearchProjection.projectRanges`, or `Published.mergeReviewRanges`.
A Review Search selection move with ranges present keeps its ranges array.
It only sets `active` in place through `markActiveSearchRanges`.
The full projection `Published.projectBufferSearchRangesFor` walks every visual row and builds a row index with one list for each source line.
Only tests call it, as an independent oracle.

Enforcement: `Published.projectBufferSearchRangesFor` and `Published.projectBufferSearchRanges` in `src/tui/presentation.zig` call `@compileError` outside a test build. A production call fails `zig build`, and also `zig build test`, because its CLI tests build the exe. The Review Search tests in `src/tui/presentation.zig`, run by `zig build test`, fail when a selection move or a source publication projects again.

## Search selection in a Buffer rebuild

A Buffer rebuild carries no search selection.
It carries neither the Review Search selection nor the Buffer Search current occurrence.
The admission that publishes a build reads the current selection.
`Published.publishReviewRanges` marks the active Review Search ranges with `review_search.selected`.
`acceptViewBuild` maps `buffer_search.active` into the rebuilt batch with `sameSearchIndex`.
The DiffPane takes the active Buffer Search ranges from that index, not from the range flags.
So a selection move never discards a running rebuild.
A build keeps an occurrence only when it opens that occurrence.
A `.review_destination` build keeps it in `destination_occurrence`.
A build whose `Kind.opensOccurrence` holds keeps it in `destination_active`.
A `.review_destination` admission drops the build after a move to another occurrence.
No other admission compares a selection.

Enforcement: `DisclosureBuild` has no `review_selected` or `accepted_active` field, and `DisclosureBuild.create` takes no occurrence (compile error). The exhaustive switch in `Kind.opensOccurrence` makes each new Kind decide whether it opens an occurrence (compile error). The admission tests in `src/tui/presentation.zig`, run by `zig build test`, fail when an admission rejects or retries a build because the selection moved. The test "Buffer Search rejects and retries an enrichment rebuild after its accepted batch changes" keeps the batch check.

## Review Search source scan failures

A File gets two source scans at most for one Review Search query.
After its first failed scan, the File keeps its Review Search hold, and the next source scan retries it.
After its second failed scan, Review Search stops the source scans of the query and shows `buffer_search_scan_failed` once.
Each File without a successful scan then stays unscanned and has no Review Search hold, so a lasting failure such as `OutOfMemory` costs two scans, not two scans for each File.
The worker boundary records each failed scan once, and Presentation records each allocation failure of a publication once.
A source result merges into the published results. So the source scans of a query start only after its results publish. `ReviewSearchState.currentQueryResultsPublished` decides the start and the merge of a source result. A query edit shows the results of `rollback_query` until its own results publish. When the Overlay closes first and its reopen cannot queue the query scan, the edited query stays in the input. The Overlay also stays pending. So it never shows a query over the results of another query without the pending mark. The `ensure_focused_enrichment` input, which the App dispatches after each event while a Review shows, queues the query scan again. A lasting failure retries only at a later dispatch of that input, never in a loop. Each failed attempt records one failure. A successful retry clears only an error of its own origin, `.review_search`. A failed retry shows `out_of_memory` when its event ends without a message. A first query that rolls back after a failed scan has no results, so it starts no source scan.
The results of a new query, or a reopened Overlay, start the source scans again.
Until the results of a query edit publish, each File keeps its source scan state, so a query that rolls back keeps the attempts and the given-up Files of its pass, and the rollback resumes that pass.
A source scan without a result, such as a queued scan that a query edit discards, returns its File to the state and the hold that it had before the scan.

A source scan command always starts, because it needs no allocation.
Its start drops the Review Search hold of its File without a cache build stage, because the lease of the command keeps the File. The completion of the scan releases that lease and stages.
The command retains the published Session and reads its File there, because a published Session never changes its Diff.
The scan result takes its own Session reference before the worker releases the command, so the Presentation thread releases the last reference of a replaced Session.
It retains the query, which Presentation allocates once for each query change in `std.heap.page_allocator`, because a worker can release its last reference.
It waits in its own slot, `Presentation.queued_source_scan`, because at most one source scan is queued or running.
An enrichment build records whether Review Search holds each File, and its worker counts that hold when it previews the cache budget.
Admission takes the recorded hold, and it retries the build when the current decision of `reviewSearchHolds` differs, because a query or Overlay change can change the decision without a Storage change.

Enforcement: "M21 kernel Review Search starts a source scan when no allocation succeeds" in `src/tui/presentation.zig` fails when a failed allocation from the Presentation allocator stops the start of a source scan. It also fails when the stop goes through a `catch` that returns. Other tests in that file check the retry, the stop, and the rollback: "M21 kernel Review Search scans a File again after its source scan fails", "M21 kernel Review Search gives up on a File after its second failed source scan", "M21 kernel Review Search stops its source scans after it gives up on a File", "M21 authored failed source scan retries after reopening Review Search", "M21 kernel Review Search keeps the given-up Files of a query edit that rolls back", and "M21 kernel Review Search resumes the retry of a query edit that rolls back". The test "M21 kernel Review Search starts no source scan before its first query publishes" fails when a source scan starts before the first query results publish. "M21 kernel Review Search starts no source scan while a query edit is pending" fails when a source scan starts while the results of the previous query show. "Review recovery a Review Search query retry clears its failed scan error" fails when the reopened Overlay drops the edited query or does not queue its scan at the next event. It also fails when the Overlay shows the edited query over the previous results without the pending mark. "M21 kernel Review Search keeps an older message when a reopened query retry succeeds" fails when the successful retry clears a message that it did not set. "M21 kernel Review Search starts its source scans after first query results without a match" fails when results without a match start no source scan. "M21 kernel Review Search starts a source scan without superseding a cache build in flight" fails when the start of a source scan stages a cache build while a cache update is pending. The test "M21 kernel Review Search admits an enrichment with the hold that its build counted" fails when admission takes a hold that the build did not count. `zig build test` runs them. An allocation from another allocator is a convention, in [CODING_STANDARDS.md](../../CODING_STANDARDS.md#a-source-scan-starts-without-an-allocation).

## Search occurrence index mapping

A search occurrence index maps into a newer batch by one of two rules.
`sameSearchIndex` in `src/tui/presentation.zig` keeps the same occurrence and gives null when the batch lost it.
A rebuild uses `sameSearchIndex`, because a rebuild does not move the cursor.
So a Buffer rebuild that removes the current Buffer Search occurrence clears `buffer_search.active`, and the cursor stays.
A rebuild that removes the Buffer Search input preview clears `input.active` through `sameSearchIndex` or `sameProjectedSearchIndex`, and the cursor stays.
`nearestSearchIndex` falls back to the nearest index.
Only a move that the user asked for, such as the retry in `retryAcceptedDisclosure`, and a list selection use it.
A retried traversal move into an empty batch sets `buffer_search_no_matches` and opens nothing.

Enforcement: `tools/check_search_index.py`, run by `zig build test`. Each function that calls a `nearest…Index` function needs an entry with a reason in its `NEAREST` table. The `M21 kernel Buffer Search` tests in `src/tui/presentation.zig`, run by `zig build test`, check the cleared occurrence, the cleared input preview, and the retry into a File without matches.

## Navigation across Frames

State that outlives its Presentation Frame holds a `frame.NavigationAnchor`, not a `Nav`.
A `NavigationAnchor` holds the cursor, its viewport offset, and the Selection mark by row identity.
Only `NavigationAnchor.resolve` against a Frame gives row numbers, so each reader resolves it against its own Frame.
The cursor restore of every admission goes through it.
The Buffer Search input holds the place where it opened as `input.start`, and no admission remaps it.
When the Frame lost that row, Escape puts the cursor at the top of the Buffer.
A `Nav` struct field sits only beside the rows of its own Frame, in `frame.Projection`, `Published`, and `ReviewProjection`.

Enforcement: `tools/check_navigation_fields.py`, run by `zig build test`. The `M21 kernel Buffer Search input Escape` tests in `src/tui/presentation.zig`, run by `zig build test`, check the return to the start after rows change above it.

## Row identity across Buffer builds

A row identity that outlives a Buffer build holds no pointer into that build.
Each build makes its own Whole File gap Lines in its arena (`spliceSide` in `src/tui/buffer.zig`), so a gap Line pointer is valid in one Frame only.
A Line row identity is a `frame.LineOwner`, and `LineOwner.of` makes it.
A Hunk Line lives as long as the Session, so its identity is its pointer.
The identity of a gap Line is its File, side, and line number.
`RowOwner.line` and `SurvivingRow.line` hold a `LineOwner`.
A `*const bbr.diff.Line` field that holds a gap Line is valid only beside the rows of its own Frame, such as `VisualHalf.line` and `YankCandidates`.

Enforcement: the `LineOwner` type of `RowOwner.line` and `SurvivingRow.line` (compile error for a Line pointer). The `M21 kernel` Whole File gap Line tests in `src/tui/presentation.zig`, run by `zig build test`. The test "M21 kernel no Line row identity of a Whole File Frame holds a gap Line pointer" fails when a visual row owner holds a gap Line in `.hunk_line`.

## Coalesced Buffer builds

A Buffer build that a background stream requests has at most one queued build of its kind, so a stream never costs one full Buffer build for each item.
The streams are File Enrichment results and Review Search lease and hold releases.
A new request joins the queued build and keeps its place.
`takeCommand` gives the build a new snapshot through `refreshQueuedBuild`.
One exception exists.
`takeCommand` gives the queued Review Search source scan before a cache update at the front of the queue while `Storage.cachePressure` is not `far_over_budget`.
Far over the budget means that the inactive Files exceed the budget by more than the larger of the budget and the floor.
The floor is `Storage.far_over_budget_floor` (4 MiB).
After each File of the Review was admitted once, the floor is at most an eighth of the bytes of the Review.
Storage keeps the bytes of each File from its last admission, also after an eviction.
So while the scans run, the inactive bytes stay at or below the budget plus that excess, plus one File.
Each cache update frees more than the excess. So the scans cost at most one full Buffer build for each excess that they release, plus one for each stop.
The floor keeps a budget smaller than one File from costing a build for each released File.
The eighth of the Review lets a small Review evict while the scans run, with about eight cache updates for each pass.
Before Storage knows the bytes of every File, it cannot tell a small Review from a large one, so the floor stays at 4 MiB.
When the scans stop, the cache update reaches the front and brings the cache within the budget.

Enforcement: the exhaustive switch in `refreshQueuedBuild` in `src/tui/presentation.zig` names every `DisclosureBuild.Kind`, so a new kind needs a decision about its snapshot at take (compile error). The build-counting and eviction tests of Review Search in `src/tui/presentation.zig` and the cache pressure test in `src/tui/file_enrichment.zig`, run by `zig build test`.

## Published Frame snapshots

A Buffer build retains the current search Batches only so that acceptance can tell whether the build is still current.
The accepted build stays alive as `Published.worker_frame`, because its arena holds the Buffer.
`acceptBufferDisclosure` releases its snapshots when it becomes the published Frame.
A later scan can replace the Batch of a snapshot. A snapshot in the Frame then keeps the replaced Batch alive, and a Review Search Batch can hold gigabytes.

Enforcement: the test "M21 kernel a Buffer build during Review Search keeps no replaced Batch after the Overlay closes" in `src/tui/presentation.zig`, run by `zig build test`.

## Review Search Preview hold

The File that the Review Search Preview shows has a hold, so a cache update never evicts the content on screen.
`holdReviewSearchPreview` runs at the end of each dispatch. It gets the held File from `ReviewSearchState.previewSource`, which the Preview projection also reads.
It acquires the File again when a cache update evicted it before the selection reached it.
`Published.releaseReviewSearchHolds` releases the hold with the scan holds.

Enforcement: the test "M21 kernel the Review Search Preview keeps its File content while cache updates evict" in `src/tui/presentation.zig`, run by `zig build test`.

## Review Search scan hold

A Review Search scan hold exists only while a source scan of its File is due.
A scan is due while the `SourceScan` of the File is `unscanned`, or `awaiting_retry` after a first failed scan.
The start of the source scan of a File releases its scan hold, and the lease of the queued or running scan keeps the File.
A `scanned` or `given_up` File gets no scan hold until the results of a new query, or a reopened Overlay, start the source scans again.
`ReviewSearchState.needsScanHold` makes this decision for every site that adds a scan hold: admission through `reviewSearchHolds`, and opening or a query change through `holdReviewSearchFiles`.
Otherwise a scanned File that the Preview acquires again, or that the Overlay holds again when it opens, keeps a hold that no scan releases, and the cache budget no longer covers it.

Enforcement: the tests "M21 kernel a scanned File that the Review Search Preview acquires again is evictable after the selection leaves it" and "M21 kernel reopening Review Search holds no File that its query already scanned" in `src/tui/presentation.zig`, run by `zig build test`. [The coding standard](../../CODING_STANDARDS.md#every-scan-hold-site-asks-needsscanhold) covers a new site that adds a scan hold.
