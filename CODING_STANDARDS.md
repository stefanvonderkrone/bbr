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

`std.Io.sleep` and `Group.await` return `error{Canceled}`, so an `else` on those calls is unreachable. An `else` on a wider set that returns the cause also returns `error.Canceled`. `std/Io.zig` says that code which ignores `error.Canceled` is usually wrong, because the next cancelation point does not signal it again.

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

A change to the key handler of an Overlay that reads keys outside the Keymap changes its section in `help.fixed_sections` in `src/tui/help.zig` too.

No check: the fixed sections are text that no compile check ties to the key handlers. Related checked rule: [Help Overlay sections](docs/rules/tui-state.md#help-overlay-sections).

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

[Maintenance work](src/tui/GLOSSARY.md) is work that no input asked for and that a later check does again. A failed queue or staging of maintenance work has exactly one record, and it never overwrites or clears another message.
A failure of maintenance work records its cause once and shows `out_of_memory` only when no message shows.
A File Enrichment or a query retry that succeeds clears only the `out_of_memory` message of an earlier failed attempt.
A cache staging or a cache update commit writes no message.
A user action that hands its work to maintenance work clears an older message before it does so.
`openReviewSearchOccurrence` clears it only on the user-input path before the acquisition pump for an evicted File.
A completion keeps the shown message.

These sites are maintenance work:

- A cache staging after a lease release or in the focus check. Both go through `stageCacheBuild`.
- The retry of a stale cache update in `retryContentBuild`, and the commit of a cache update in `acceptBufferDisclosure`.
- The File Enrichment of the active File in the focus check, and the File Enrichments of the Review Search acquisition, `pumpReviewSearchAcquisition`. Both go through `queueMaintenanceFileEnrichment`.
- The Review Search retry, `retryReviewSearchQuery`, of a query whose scan could not queue.
- Dropped non-speculative enrichment results in `dropEnrichments`, unless the drop cancels the pending reading location of a Refresh or Reconciliation.
- A failed enrichment build in `acceptBufferDisclosure`, with the same pending reading location exception.

`dropEnrichments` keeps its `.completion`, `.admission` record.
A speculative-only drop records the failure without a message.
A worker records a failed enrichment build before its completion.
That completion adds no record and shows `buffer_build_failed` only when no message shows or it cancels a pending reading location.

`failMaintenance` writes the record and the message of a failure, so a new site calls it in its `catch`.
The query retry is the exception. `replaceReviewSearchQuery` also serves user input, so it records the failure, and `retryReviewSearchQuery` restores the shown message after it.
The event loop in `src/tui/app.zig` dispatches `ensure_focused_enrichment` after each event while a Review shows.
This focus check, `ensureFocusedEnrichment`, stages the cache build again while the cache is over the budget, and it queues the File Enrichment of the active File again while the File is pending.
While a cache update is pending, the focus check stages after that update commits.
A File that the acquisition cannot queue stays pending and unacquired, so the next pump queues it again.
So a failure loses no work and keeps the session.
The message of the event outcome stays, such as `buffer_search_scan_failed` or `file_enrichment_launch_failed`.

No check: the tests cover only the current sites, and they dispatch `ensure_focused_enrichment` themselves. A new site that queues maintenance work and sets `action_error` passes every check, and so does an event loop that stops the dispatch after an event. Related checked rule: [Review Search source scan failures](docs/rules/tui-state.md#review-search-source-scan-failures).

### A dropped user input shows its failure

A completion that finds its build stale queues the work of a user input again. When the retry cannot queue, the work is dropped, and no later check does it again. So it is not maintenance work.
The failure of a user input is the outcome of that input. So the retry records the cause once and shows `out_of_memory` over another message.
`failDroppedInput` does both.
These retries call it: `retryViewBuild`, `retryAcceptedDisclosure`, `retryStaleBufferDisclosure`, `republishPostedParent`, and the `.draft_save` and `.draft_mutation` prongs of `retryContentBuild`.
An enrichment drop that cancels a pending reading location from Refresh or Reconciliation drops part of that input.
No later check restores the canceled location, so `dropEnrichments` calls `failDroppedInput` for that case too.

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
