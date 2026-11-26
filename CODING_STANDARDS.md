# Coding standards

This file holds the rules of bbr that no check enforces.
A reviewer checks each change against them, because nothing fails when a change breaks one.
Each standard names why no check covers it and links the checked rule beside it.
The checked rules are in the area docs under `docs/rules/`. [The rule areas guide](docs/agents/rule-areas.md) sorts a new rule.
When a check can cover a standard, add the check and delete the standard.

## Diagnostics

### A boundary message never shows the name Reported

A boundary that maps errors to user messages or shows `@errorName(err)` names `error.Reported` in its own prong. Without that prong, the user sees the name `Reported` instead of a message.

No check: the record count does not depend on the prong, so no test fails when the prong is missing. Related checked rule: [A boundary records every error except error.Reported](docs/rules/diagnostics.md#a-boundary-records-every-error-except-errorreported).

### A record outside a handler is not followed by a plain error return

Code that records a failure outside a `catch` or `errdefer` handler does not then return a plain error. It returns `diagnostic.fail(phase, cause, @src())`, or it returns the error without a record.

No check: `tools/check_diagnostics.py` reads only `catch` and `errdefer` handlers. Related checked rule: [A failure has one record](docs/rules/diagnostics.md#a-failure-has-one-record).

### A task argument holds no slot behind a pointer

A task argument holds no `Handle` with a slot behind a pointer or a type-erased source, such as the Client in a `BlobSource`. A task gets only its own slot by pointer and binds it with `withLeaf`.

No check: `anyopaque` has no type to walk. A walk through typed pointers reaches shared state that a task must reach, such as the `PagedLists` slots. Related checked rule: [A task gets its slot by pointer](docs/rules/diagnostics.md#a-task-gets-its-slot-by-pointer).

### A fan-out moves the slot to its own parent

After the join, a fan-out moves the slot of the returned failure with `Handle.adopt` to the slot of its own parent, not to another slot.

No check: the parent is a runtime value of the same type as every other slot. Related checked rule: [A task gets its slot by pointer](docs/rules/diagnostics.md#a-task-gets-its-slot-by-pointer).

### Each new task spawn is reached by a Debug test

Each new production task spawn has a test that reaches it in a Debug build. Without such a test, nothing checks the task arguments of that spawn. The existing worker spawns in `drainPresentationCommands` in `src/tui/app.zig` have no such test. [Ticket 05](.scratch/agents-md-pointers/issues/05-check-that-a-debug-test-reaches-each-task-spawn.md) adds the tests and a check.

No check: the slot check in `diagnostics.concurrent` and `diagnostics.selectConcurrent` runs only in a Debug build, because a release panic would end a review over lost evidence. Related checked rule: [A task gets its slot by pointer](docs/rules/diagnostics.md#a-task-gets-its-slot-by-pointer).

### A catch names error.Canceled

A `catch` whose error set contains `error.Canceled` names `error.Canceled`. The prong does one of these:

- It returns `error.Canceled`.
- It calls `io.recancel()`.
- It stands under `io.swapCancelProtection(.blocked)` and is `unreachable`.

`std.Io.sleep` and `std.Io.Group.await` return `error{Canceled}`, so an `else` on those calls is unreachable. An `else` on a wider set that returns the cause also returns `error.Canceled`. `std/Io.zig` says that code which ignores `error.Canceled` is usually wrong, because the next cancelation point does not signal it again.

No check: a line check cannot see an error set, and a list of call names misses a `try` through another function. The compiler rejects a missing `error.Canceled` prong only when the `switch` has no `else`. Related checked rule: [A catch captures and records its cause](docs/rules/diagnostics.md#a-catch-captures-and-records-its-cause).

## Build and checks

### Buffer builds in benchmarks set cell metrics

A benchmark Buffer build sets `cell_metrics` to `tui.terminal_cell_metrics`. A build that omits `cell_metrics` gets the `.bytes` default of `BuildOptions` in `src/tui/buffer.zig`. No file keeps its own copy of the vaxis adapter.

No check: `tools/check_benchmark_metrics.py` looks for the `.bytes` name, so it cannot see a default that a build gets by omission, or a second copy of the adapter. Related checked rule: [Benchmark cell metrics](docs/rules/build-and-checks.md#benchmark-cell-metrics).

## TUI paint

### Fixed scroll bars in a layout tree

A layout tree always declares its scroll bars, and only the scroll numbers vary. Presentation solves a tree without the scroll numbers. A scroll bar that comes and goes would move a padding or margin ring between hit testing and paint.

No check: no check enforces it. `layouts.Scroll` is not optional in the existing trees, but a new tree can still leave out a scroll bar. Related checked rule: [Slot placement](docs/rules/tui-paint.md#slot-placement).

## TUI state

### Choose the origin of an action error

Add a `withErrorOrigin` override only for work that belongs to another path than its event, such as a pump that runs after the inputs of every event.
Choose the origin of the path whose completion must clear the error.
A user handler overrides only for an error that a later completion of another path must clear.
Name the reason in a comment at each override.
When an error must stay through a completion of its own event path, give the path its own `ErrorOrigin` instead of an override, as Draft builds have `.draft`.

No check: the type and the line check see that only the event and `withErrorOrigin` set the origin, and that each override names an enum literal, but not that an override names the right path. Related checked rule: [Background work keeps an unrelated action error](docs/rules/tui-state.md#background-work-keeps-an-unrelated-action-error).

### Reserve storage in every rebuild

Other rebuilds follow the Buffer rebuild storage rule too, such as the search candidates and the search projection ranges.
Each list or map whose size is known before its loop reserves that size first.

No check: a line check cannot follow an allocator through a parameter or a default, and the appends sit in helpers such as `Weave` methods. Related checked rule: [Buffer rebuild storage](docs/rules/tui-state.md#buffer-rebuild-storage).

### Index entries need a reader

An index other than `NavigationIndex` that each rebuild fills holds no entry without a named reader.

No check: a line check cannot see who reads a map entry. Related checked rule: [Rebuild index entries](docs/rules/tui-state.md#rebuild-index-entries).

### No change to a published Session

No code uses `@constCast` or a field reassignment on a Session after publication.
After publication, no code writes the Diff, Threads, or mention names of a Session through a mutable alias.
A buffer that the producer keeps to free later is such an alias.

No check: `read_only.assert` stops a write only through the Session fields. It does not stop a write through a mutable alias. Test fixtures change a Session before `Presentation.init`, and no text check can see publication or follow an alias. Related checked rule: [Published Session content](docs/rules/tui-state.md#published-session-content).

### No scan of every row for one File

A question about one File uses no `while` loop over all rows, no call through a helper, and no scan without `fileIndexForRow`, such as `hasBodyOwner` of ticket 22.

No check: `tools/check_row_scans.py` sees only a `fileIndexForRow` call directly in a `for` loop over all rows. Related checked rule: [Questions about one File](docs/rules/tui-state.md#questions-about-one-file).

### Fixed help sections follow their key handlers

A change to the key handler of an Overlay or input that reads keys outside the Keymap changes its section in `help.fixed_sections` in `src/tui/help.zig` too.
This covers the Enter and Escape keys of an armed re-anchor, and a new `if` in `Presentation.applyKey` outside the `help.FixedKeyInput` switch.

No check: the fixed sections are text that no compile check ties to the key handlers. The exhaustive switch sees only a new `FixedKeyInput` value, not a key handler outside the switch. Related checked rule: [Help Overlay sections](docs/rules/tui-state.md#help-overlay-sections).

### Only showMainPane writes the Main Pane

Only `Published.showMainPane` writes `Published.main_pane` after init. The draw loop in `src/tui/app.zig` paints only one Pane.

No check: a field write is plain Zig, and no check finds a second writer. The paint test sees the result of one draw, not the structure of the loop. Related checked rule: [Main Pane](docs/rules/tui-state.md#main-pane).

### Every destination build publishes the DiffPane

The `card_destination` arm of `Kind.publishedPane` returns the DiffPane.

No check: `landOnCard` shows the DiffPane too, so no test fails when the arm returns no Main Pane. Related checked rule: [Submission Overlay jump shows the DiffPane](docs/rules/tui-state.md#submission-overlay-jump-shows-the-diffpane).

### Presentation imports no vaxis and no Theme

`presentation.zig` does not import vaxis or `theme.zig`.
The Theme reaches Presentation only as a `ThemeId`.

No check: `presentation.zig` imports `keymap.zig`, and `keymap.zig` imports vaxis, so an import check would see vaxis in the import graph. Related checked rule: none.

### No full projection on a frequent path

Production code does not call `projectRanges` on a frequent path other than the ones that exist.

No check: the compile error covers only the full projection, and no check knows which path is frequent. Related checked rule: [Search range projection](docs/rules/tui-state.md#search-range-projection).

### Destination fields belong to builds that open an occurrence

A build kind that does not open an occurrence reads no destination field.
This holds until [ticket 15](.scratch/enrichment-rebuild-follow-up/issues/05-carry-the-search-destination-in-the-build-kind.md) decides it.

No check: the destination fields are not yet part of the build kind. Related checked rule: [Search selection in a Buffer rebuild](docs/rules/tui-state.md#search-selection-in-a-buffer-rebuild).

### Choose the rule for a new NEAREST entry

A new entry in the `NEAREST` table of `tools/check_search_index.py` uses `nearestSearchIndex` only for a move that the user asked for or a list selection.

No check: the check needs a reason for the entry, but it cannot judge the reason. Related checked rule: [Search occurrence index mapping](docs/rules/tui-state.md#search-occurrence-index-mapping).

### No row number in state that outlives its Frame

State that outlives its Frame holds no row number in a `usize` field, such as the old `origin` and `VersionRestoration.visual_row`.
A `Nav` field whose type spans lines follows the Navigation across Frames rule too.

No check: a line check cannot tell a row number from another `usize`, and it reads a `Nav` field type only on one line. Related checked rule: [Navigation across Frames](docs/rules/tui-state.md#navigation-across-frames).

### A source scan starts without an allocation

The start of a Review Search source scan, `maybeQueueReviewSourceScan` and `ScanReviewSource.create`, allocates from no allocator.
It also stages no cache build, because the lease of the scan keeps its File. The test "M21 kernel Review Search starts a source scan without superseding a cache build in flight" fails when the start stages a cache build while a cache update is pending, whatever its allocator.

No check: the test "M21 kernel Review Search starts a source scan when no allocation succeeds" fails only when a failed allocation from the Presentation allocator stops the start. An allocation from `std.heap.page_allocator` or from the Session allocator passes it, and so does an allocation whose failure the start ignores. A `catch` makes any allocation compile in a function that returns no error union. Related checked rule: [Review Search source scan failures](docs/rules/tui-state.md#review-search-source-scan-failures).

### Maintenance work keeps the shown message

[Maintenance work](src/tui/GLOSSARY.md) is work that no input asked for and that a later check does again.
A failure of maintenance work records its cause once and shows its failure message only when no message shows.
An allocation failure uses `out_of_memory`.
A failed enrichment or cache update build uses `buffer_build_failed`.
[A failed Buffer build has its record from the worker boundary](docs/rules/diagnostics.md#a-failed-buffer-build-has-its-record-from-the-worker-boundary).
A success clears only an error of its own origin, by [Background work keeps an unrelated action error](docs/rules/tui-state.md#background-work-keeps-an-unrelated-action-error).
A successful cache staging writes no message.
A user action that hands its work to maintenance work calls `clearError` before it does so, as `openReviewSearchOccurrence` does before the acquisition pump for an evicted File.

These sites are maintenance work:

- A cache staging after a lease release or in the focus check. Both go through `stageCacheBuild`.
- The retry of a stale cache update in `retryContentBuild`.
- The File Enrichment of the active File in the focus check, and the File Enrichments of the Review Search acquisition, `pumpReviewSearchAcquisition`. Both go through `queueMaintenanceFileEnrichment`.
- The Review Search retry, `retryReviewSearchQuery`, of a query whose scan could not queue.
- A failed enrichment build in `acceptBufferDisclosure` that cancels no pending reading location, `pending_review_location`, and a failed cache update build. `DisclosureBuild.Kind.isMaintenance` names these two build kinds, and its exhaustive switch makes a new build kind choose.
- A non-speculative result that `dropEnrichments` drops when it cancels no pending reading location.

`dropEnrichments` records with operation `.completion` and phase `.admission`.
A speculative-only drop records the failure without a message.

`failMaintenance` writes the record and the message of a failed queue or staging, so a new such site calls it in its `catch`.
A function that also serves user input, such as `setReviewSearchQuery`, records its failure and returns `error.Reported` without a message.
Then each caller picks the message.
The event loop in `src/tui/app.zig` dispatches `ensure_focused_enrichment` after each event while a Review shows.
This focus check, `ensureFocusedEnrichment`, stages the cache build again while the cache is over the budget, and it queues the File Enrichment of the active File again while the File is pending.
While Review Search is open, the focus check queues no File of its range and pumps the acquisition after its range work, also after a cache staging or with an empty range.
A failed queue can leave no File Enrichment in flight, and then no completion pumps again.
While a cache update is pending, the focus check stages a new cache build only when the focus changed since that update was staged.
A File that the acquisition cannot queue stays pending and unacquired, so a later pump queues it again, such as the pump of a later focus check while Review Search is open.
So a failure loses no work and keeps the session.
The message of the event outcome stays, such as `buffer_search_scan_failed` or `file_enrichment_launch_failed`.

No check: the tests cover only the current sites, and they dispatch `ensure_focused_enrichment` themselves. A new site that queues maintenance work and calls `showError` without the check of a shown message passes every check, and so does an event loop that stops the dispatch after an event. Related checked rule: [Review Search source scan failures](docs/rules/tui-state.md#review-search-source-scan-failures).

### A dropped user input shows its failure

A completion that finds its build stale queues the work of a user input again. When the retry cannot queue, the work is dropped, and no later check does it again. So it is not maintenance work.
The failure of a user input is the outcome of that input. So the retry records the cause once and shows `out_of_memory` over another message.
`failDroppedInput` does both.
These retries call it: `retryViewBuild`, `retryAcceptedDisclosure`, `retryStaleBufferDisclosure`, `republishPostedParent`, and the `.draft_save` and `.draft_mutation` prongs of `retryContentBuild`.
`selectVersion` also calls it when its view build or its File Enrichment cannot queue, because no later check does that input again.
So does `replaceReviewSearchQuery` when a query edit or a reopened query cannot allocate or queue its scan.
An enrichment failure can cancel the pending reading location from a refresh or Reconciliation.
That cancellation drops part of the refresh or Reconciliation.
No later check restores the canceled location.
`dropEnrichments` calls `failDroppedInput` for that case too.
The completion of a failed enrichment build shows `buffer_build_failed` for that case.

No check: the tests cover only the current retries. A new retry that shows `out_of_memory` without a record passes `tools/check_diagnostics.py`, because the check accepts a `catch` that names `error.OutOfMemory` in a switch prong and drops it. Related checked rule: [A failure has one record](docs/rules/diagnostics.md#a-failure-has-one-record).

### Make Line row identities through LineOwner.of

No code writes a literal `.{ .hunk_line = line }` that bypasses `LineOwner.of`.
No new `*const bbr.diff.Line` field outlives its Frame.

No check: a field check cannot tell a Hunk Line from a gap Line, because both have the type `*const bbr.diff.Line`. Every existing Line pointer field is Frame-scoped or holds only Hunk Lines, so each existing field would be an exception. Related checked rule: [Row identity across Buffer builds](docs/rules/tui-state.md#row-identity-across-buffer-builds).

### Only a Review Search source scan passes the queued cache update

A queued cache update keeps its place in the queue. Only the queued Review Search source scan goes before it, and only while the cache is not far over the budget. Far over the budget is a byte limit that depends only on the budget and on the bytes of the Review, never on a File count. The bytes of the Review count only after each File was admitted once. Another request that passes it can starve the cache update and hold the cache over the budget.

No check: a check would have to know every request that can reach the queue. Related checked rule: [Coalesced Buffer builds](docs/rules/tui-state.md#coalesced-buffer-builds).

### A surface that shows File content protects it from eviction

A surface that reads File content from the cache keeps that File out of eviction while it shows it. The DiffPane does this through the cache focus, and the Review Search Preview through its hold. A cache update evicts every other inactive File, and nothing acquires a File again only because a surface reads it.

No check: a check cannot tell which projection field a painter reads as File content. Related checked rule: [Review Search Preview hold](docs/rules/tui-state.md#review-search-preview-hold).

### Every scan hold site asks needsScanHold

A site that adds a Review Search scan hold decides it through `ReviewSearchState.needsScanHold`. A hold that the site adds on its own can land on a File whose scan is not due. No scan then releases that hold, and the cache budget no longer covers the File.

No check: a check would have to know every path that reaches `enrichment.hold` for Review Search. Related checked rule: [Review Search scan hold](docs/rules/tui-state.md#review-search-scan-hold).
