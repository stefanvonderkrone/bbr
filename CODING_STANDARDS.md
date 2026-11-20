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

### A new layout tree joins the fixed scroll bar test

A new layout tree with a scroll bar always declares it, and its solve joins the test that compares the rects at different scroll numbers.

No check: the test solves only `panes`, `reviewSearch`, and `help`. `layouts.Scroll` is not optional in the existing trees, but a new tree can still leave out a scroll bar. Related checked rule: [Fixed scroll bars in a layout tree](docs/rules/tui-paint.md#fixed-scroll-bars-in-a-layout-tree).

### One drag path for each scroll bar

Presentation maps a Scroll Drag pointer to an offset only through `view.dragOffset`. A second drag path in Presentation that does its own arithmetic is not allowed.

No check: a test checks the drag result of each scroll bar, but a second path with the same result in the tested cases passes. Related checked rule: [Scroll bar arithmetic](docs/rules/tui-paint.md#scroll-bar-arithmetic).

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

### Make Line row identities through LineOwner.of

No code writes a literal `.{ .hunk_line = line }` that bypasses `LineOwner.of`.
No new `*const bbr.diff.Line` field outlives its Frame.

No check: a field check cannot tell a Hunk Line from a gap Line, because both have the type `*const bbr.diff.Line`. Every existing Line pointer field is Frame-scoped or holds only Hunk Lines, so each existing field would be an exception. Related checked rule: [Row identity across Buffer builds](docs/rules/tui-state.md#row-identity-across-buffer-builds).
