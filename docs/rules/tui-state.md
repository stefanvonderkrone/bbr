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
`Presentation.action_error` holds a `ShownError`, which pairs the `ActionError` with an `ErrorOrigin`.
Code writes it only through `showError` and `clearError`, and neither takes an origin.
Both read `Presentation.event_origin`, the origin of the event that runs.
`dispatch` sets the event origin from `OwnedInput.errorOrigin` and restores it when the event ends.
A key, a mouse action, or an Overlay action has the origin `.user`, and its `clearError` clears any error.
A completion of background work has the origin of its own path, and its `clearError` clears only an error of that origin.
Thus a completion keeps an error that another path showed and that the user has not read yet.
A helper that keys and completions both reach takes the origin of the event that reaches it.
A Buffer build completion takes its origin from `DisclosureBuild.Kind.errorOrigin`.
Draft save and Draft mutation builds have the origin `.draft`, separate from view builds.
Buffer Search scans and search disclosure builds use `.buffer_search`.
Review Search scans use `.review_search`.
An input that shows and clears no action error has no origin.

Some work runs inside an event but belongs to another path.
It names its origin through `withErrorOrigin`, which restores the origin of the event after the work.
These overrides exist:

- `dispatch` runs `holdReviewSearchPreview` after each event as `.review_search`, because the Preview hold acquires Files for Review Search.
- The focus check runs `retryReviewSearchQuery` as `.review_search`, so a successful retry clears only a Review Search error.
- `openReviewSearch` runs `replaceReviewSearchQuery` for a reopened query as `.review_search`, so its scan clears only a Review Search error.
- `applySubmissionTreeKey` shows `replacement_pending` as `.reconciliation`, so the end of the replacement clears the notice.
- `init` runs `discoverRecovery` as `.submission`, because recovery belongs to the Submission path.
- After an allocation failure, `takeCommand` runs `requestShutdown` as `.submission`, because shutdown resumes a paused Submission.

Outside `dispatch` and `withErrorOrigin` the event origin is null.
Then `showError` panics, because no event names the origin.
`clearError` returns early when no error shows.
Outside an event, `clearError` panics only while an error shows.
A test that calls a method directly runs it through a test helper such as `showTestError`, which calls `withErrorOrigin`.
The File Enrichment path includes enrichment builds, cache updates, and the focus check that starts a File Enrichment.
A speculative enrichment shows and clears no action error.
The Projection still gives only the `ActionError`.

Enforcement: the exhaustive switches in `OwnedInput.errorOrigin` and `DisclosureBuild.Kind.errorOrigin` in `src/tui/presentation.zig` cause a compile error for a new input or a new build kind without an origin. `tools/check_action_errors.py` and `tests/check_action_errors_test.py` run under `zig build test`. The checker fails on a write of `action_error` outside `showError` and `clearError`, such as `self.action_error = null` in a completion. It also fails on a write of `event_origin` outside `dispatch` and `withErrorOrigin`, and it names `withErrorOrigin` as the fix. The checker does not see a write through a pointer, such as `slot.* = null` after `const slot = &self.action_error`. The same limit holds for `event_origin`. The `Review recovery` tests in the same file check that each completion keeps an unrelated action error, that the Submission, a Comment delete, and a cache update still clear an error of their own origin, that a view build keeps a Draft error and the error of a failed Draft jump, and that a user retry of a Submission or of a recovery clears an unrelated error. `zig build test` runs them.

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
The source scans of a query start only after its results publish, because a source result merges into the published results. `ReviewSearchState.currentQueryResultsPublished` decides the start and the merge of a source result. A query edit shows the results of `rollback_query` until its own results publish. When the Overlay closes first and its reopen cannot queue the query scan, the edited query stays in the input and the Overlay stays pending, so it never shows a query over the results of another query without the pending mark. The `ensure_focused_enrichment` input, which the App dispatches after each event while a Review shows, queues the query scan again. A lasting failure retries only at a later dispatch of that input, never in a loop. Each failed attempt records one failure. A successful retry clears only the out-of-memory message of the failed scan, because a message that an earlier input of the same event set must stay. A first query that rolls back after a failed scan has no results, so it starts no source scan.
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

Enforcement: the test "M21 kernel Review Search starts a source scan when no allocation succeeds" in `src/tui/presentation.zig` fails when a failed allocation from the Presentation allocator stops the start of a source scan, also through a `catch` that returns. The tests "M21 kernel Review Search scans a File again after its source scan fails", "M21 kernel Review Search gives up on a File after its second failed source scan", "M21 kernel Review Search stops its source scans after it gives up on a File", "M21 authored failed source scan retries after reopening Review Search", "M21 kernel Review Search keeps the given-up Files of a query edit that rolls back", and "M21 kernel Review Search resumes the retry of a query edit that rolls back" in the same file check the retry, the stop, and the rollback. The test "M21 kernel Review Search starts no source scan before its first query publishes" fails when a source scan starts before the first query results publish, "M21 kernel Review Search starts no source scan while a query edit is pending" fails when a source scan starts while the results of the previous query show, "Review recovery a Review Search query retry clears its failed scan error" fails when the reopened Overlay drops the edited query, shows it over the results of the previous query without the pending mark, or does not queue its scan at the next event, "M21 kernel Review Search keeps another message of the same event when a reopened query retry succeeds" fails when the successful retry clears a message that it did not set, and "M21 kernel Review Search starts its source scans after first query results without a match" fails when results without a match start no source scan. The test "M21 kernel Review Search starts a source scan without superseding a cache build in flight" fails when the start of a source scan stages a cache build while a cache update is pending. The test "M21 kernel Review Search admits an enrichment with the hold that its build counted" fails when admission takes a hold that the build did not count. `zig build test` runs them. An allocation from another allocator is a convention, in [CODING_STANDARDS.md](../../CODING_STANDARDS.md#a-source-scan-starts-without-an-allocation).

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

## Scroll bar targets

Hit testing and the Scroll Drag read the scroll numbers through `frame.scrollTarget`. It gives the numbers only while the bar shows a thumb and no other Overlay covers the bar.

Enforcement: the test "M30 scrollbar a track without a thumb or under an Overlay has no scroll bar target" in `src/tui/frame.zig`. The test "M30 scrollbar the help track takes a press and a Scroll Drag and the help stays open" in `src/tui/presentation.zig`. `zig build test` runs them.

## Scroll Drag

A Scroll Drag starts with an unmodified left press on a track. It captures every left drag event until the release. The pointer column does not matter. A pointer past a track end pins the thumb at that end. Every other mouse event, key input, and a Session replacement end the Scroll Drag. It also ends when `frame.scrollTarget` gives no numbers for its bar.

Enforcement: the tests "M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends", "M30 scrollbar key input and a Session replacement end a Scroll Drag", "M30 scrollbar a release activates nothing and a motion, a wheel, or another press ends a Scroll Drag", and "M30 scrollbar a Scroll Drag ends when its thumb goes away" in `src/tui/presentation.zig`, run by `zig build test`.

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
