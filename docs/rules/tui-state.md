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
Some Overlays and inputs read keys outside the Keymap, such as the Submission Overlay, the delete confirmation, the Comment Overview query input, and the help itself.
Their fixed keys are in `help.fixed_sections` in `src/tui/help.zig`.
Each such input is one value of `help.FixedKeyInput`, and `applyKey` in `src/tui/presentation.zig` switches on `Presentation.fixedKeyInput`.

Enforcement: the exhaustive switch in `keymap.helpSection` (compile error for a new Action). The exhaustive switch on `help.FixedKeyInput` in `Presentation.applyKey`, and `std.EnumArray(FixedKeyInput, FixedSection).init` in `help.fixed_sections`, fail to compile for a new input. The second error is `missing struct field` with the name of the input.

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
A File Jump also shows the DiffPane.
A File Tree File is a File Jump only while the DiffPane shows.
While the Comment Overview shows, Enter or a click on a File Tree File moves focus to the Comment Overview.
A File Finder choice calls `showDiffPane` before the File Jump.

Enforcement: the tests "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File", "M29 overview a File Jump shows the DiffPane", and "M29 overview Enter on a File Tree File while the Comment Overview shows moves focus to the Comment Overview" in `src/tui/presentation.zig`, run by `zig build test`.

## File Tree cursor follows the active File

While the DiffPane shows and has focus, the File Tree cursor follows the active File.
`revealActiveFile` moves it.
Keyboard, mouse, and view-build paths all call `revealActiveFile` when the active File changes.
While the Comment Overview shows, `revealActiveFile` and `centerActiveFile` do nothing, and `focusPane` does not call `cursorToActiveFile`.
Thus the File Tree cursor stays on the File Tree Filter.

Enforcement: the tests "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File", "M21 kernel active File reveal without collapsed ancestors needs no allocation or Buffer rebuild", "M29 overview the File Tree cursor stays on the File Tree Filter", and "M29 overview a File build or a height change in the Comment Overview keeps the File Tree cursor and scroll" in `src/tui/presentation.zig`, run by `zig build test`.

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

## Main Pane

The Main Pane shows the DiffPane or the Comment Overview, never both.
`Published.main_pane` in `src/tui/presentation.zig` decides it.
Only `Published.showMainPane` changes it after init, and it gives the Main Pane focus.
When the Comment Overview hides, `showMainPane` closes the query input and cancels a pending Overview destination.
A Session replacement shows the DiffPane and resets the Overview State.

Enforcement: the exhaustive switch on `MainPane` in the draw loop of `src/tui/app.zig` (compile error for a new arm). The test "M29 overview the Main Pane paints one Pane at a time" in `src/tui/render.zig`, and the tests "M29 overview a Session replacement shows the DiffPane and resets the Overview State", "M29 overview a destination that lands closes the query input and keeps the query", and "M29 overview a File Jump shows the DiffPane" in `src/tui/presentation.zig`, run by `zig build test`.

## Comment Overview lists the DiffPane ReviewCards

The Comment Overview lists exactly the Comments and Drafts that the DiffPane shows as ReviewCards with every disclosure open.
`comment_overview.buildIndex` reads them from `buffer.reviewCardNodes`, so the two views share one parent resolution.
Listing never changes a disclosure.

Enforcement: the tests "M29 overview the index lists the DiffPane ReviewCards with every disclosure open" in `src/tui/comment_overview.zig` and "M29 overview showing the Comment Overview changes no disclosure" in `src/tui/presentation.zig`, run by `zig build test`.

## Overview Entry opens its ReviewCard

An Overview Entry names its Comment or Draft by `review_card.Owner`.
`open_overview_entry` puts the DiffPane cursor on the ReviewCard header row of that Owner.

Enforcement: the test "M29 overview Enter puts the ReviewCard header under the cursor for every CommentScope" in `src/tui/presentation.zig`, run by `zig build test`.

## Comment Overview Frame borrows its State

`comment_overview.Frame.state` is a `*const State` that borrows the Overview State from `Published`.
No `comment_overview.Frame` field holds an array by value.
vaxis cells keep their text until render, so a copy of the query buffer on a stack leaves dangling cells.

Enforcement: the `comptime` block in `comment_overview.Frame` in `src/tui/comment_overview.zig`. Its `@compileError` names the field that holds an array by value.

## Main Pane of a DisclosureBuild

Each `DisclosureBuild.Kind` in `src/tui/presentation.zig` names the Main Pane that it publishes in `Kind.publishedPane`.
It also names in `Kind.buildsSearchCorpus` whether it builds a new Buffer Search corpus.
The worker builds the File Tree for that Main Pane, and `acceptViewBuild` sets `Published.main_pane` from it.
When the Main Pane leaves the Comment Overview, `acceptViewBuild` closes the query input and keeps the query.

Enforcement: the exhaustive switches in `Kind.publishedPane` and `Kind.buildsSearchCorpus` (compile error for a new kind). The tests "M29 overview a File-level or inline Review Search result from the Comment Overview shows the DiffPane once" and "M29 overview a destination that lands closes the query input and keeps the query" in `src/tui/presentation.zig`, run by `zig build test`.

## Submission Overlay jump shows the DiffPane

A Submission Overlay jump to a card shows the DiffPane on both paths.
`landOnCard` calls `showDiffPane` first.
A failed change goes through `failCardDestination`, which shows the Submission Overlay again.
The `card_destination` build publishes the DiffPane through `Kind.publishedPane`.

Enforcement: the tests "M29 overview a Submission Overlay jump to a shown Draft card shows the DiffPane" and "M29 overview a failed DiffPane change during a Draft jump shows the Submission Overlay again" in `src/tui/presentation.zig`, run by `zig build test`.

## Armed re-anchor keys in the Comment Overview

An armed re-anchor claims Enter and Escape in `applyKey` only while the DiffPane shows.
While the Comment Overview shows, Enter opens the selected Overview Entry, and the re-anchor stays armed.

Enforcement: the test "M29 overview Enter opens the entry and leaves an armed re-anchor alone" in `src/tui/presentation.zig`, run by `zig build test`.

## Overview filters

The Overview Listing and the Review Search route decide each `comment_overview.Filter` through the one `passes` switch in `src/tui/comment_overview.zig`.
`keeps` and `hidingFilters` call it.
The route clears only the filters that `hidingFilters` returns.
A new filter is one arm of `Filter`.

Enforcement: the exhaustive switches on `Filter` in `passes` and `State.clear` (compile error for a new arm). The test "M29 overview the Review Search route clears only the filters that hide the item and keeps the order" in `src/tui/presentation.zig`, run by `zig build test`.

## Directory File Tree Filter in the Comment Overview

A Directory File Tree Filter matches an Overview item by `Record.tree_path` in `src/tui/comment_overview.zig`.
It is the display path of the File of the item, as in the File Tree.
An item outside the Diff uses its scope path.

Enforcement: the test "M29 overview the Directory File Tree Filter places a renamed File by its display path like the File Tree" in `src/tui/comment_overview.zig`, run by `zig build test`.

## Coalesced Buffer builds

A Buffer build that a background stream requests has at most one queued build of its kind, so a stream never costs one full Buffer build for each item.
The streams are File Enrichment results and Review Search lease and hold releases.
A new request joins the queued build and keeps its place.
`takeCommand` gives the build a new snapshot through `refreshQueuedBuild`.
One exception exists.
A new Review Search source scan moves the queued cache update to the end of the queue while `Storage.cachePressure` is not `far_over_budget`.
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
Queueing the source scan of a File releases its scan hold, and a scanned File never gets a scan hold again.
`ReviewSearchState.needsScanHold` makes this decision for every site that adds a scan hold: admission through `reviewSearchHolds`, and opening or a query change through `holdReviewSearchFiles`.
Otherwise a scanned File that the Preview acquires again, or that the Overlay holds again when it opens, keeps a hold that no scan releases, and the cache budget no longer covers it.

Enforcement: the tests "M21 kernel a scanned File that the Review Search Preview acquires again is evictable after the selection leaves it" and "M21 kernel reopening Review Search holds no File that its query already scanned" in `src/tui/presentation.zig`, run by `zig build test`. [The coding standard](../../CODING_STANDARDS.md#every-scan-hold-site-asks-needsscanhold) covers a new site that adds a scan hold.
