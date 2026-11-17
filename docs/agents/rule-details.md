# Rule details

Each section holds the full text of one row of the rules table in [`AGENTS.md`](../../AGENTS.md).
The table keeps a one-sentence rule and the check that enforces it.
A section names the tests, the old commits that fail them, and the parts that no check covers.

## Buffer rebuild storage

### Rule

A Buffer build appends its rows to a list in the result allocator.
It reserves the list once from `rowCapacity` in `src/tui/buffer.zig`.
It returns the list with `toOwnedSlice`, not with a `dupe`.
`BuildOptions.scratch_allocator` holds only ReviewCard projection scratch.
A rebuild list or map whose size is known before its loop reserves that size first: the visual rows in `frame.buildVisualRowsWithOptions`, and the `owners` map in `NavigationIndex.build`.
A rebuild map from a key to a list of entries is a `KeyLists` in `src/tui/key_lists.zig`, not a map with one list for each key.
`KeyLists.build` counts the entries of each key first, so all lists share one entry array and no list grows.
`NavigationIndex.spans`, `SearchProjection.source_rows`, and `SearchProjection.body_rows` use it.
A reservation is a hint, never a limit.

### Enforcement

The test "a Buffer build without ReviewCards builds its rows in the result storage" in `src/tui/buffer.zig` passes `std.testing.failing_allocator` as scratch storage.
The scratch row list of commit `ea10317` fails it.
The test "rowCapacity holds every row of a Buffer build" checks the estimate.
`zig build test` runs both.
The tests "visual rows build in one allocation without a growth copy in both Layouts", "a NavigationIndex whose keys each have one span grows nothing", and "a NavigationIndex build allocates the same for any key count and grows no key list" in `src/tui/frame.zig` count the allocations, failed remaps, and frees that a build asks of its arena.
The old visual row loop of commit `9601be3` fails the first with 2 allocations, the old `NavigationIndex.build` fails the second with 20 replaced tables, and the per-key span lists of commit `38445a9` fail the third with 2,049 allocations for 512 rows and 16,385 for 4,096 rows.
The tests in `src/tui/key_lists.zig` check the call order of each list and the release of every failed allocation.
The tests "a narrow Unified Line grows beyond the visual row capacity hint without leaks" in `src/tui/frame.zig` and "a SideBySide replacement grows beyond the source key capacity hint without leaks" in `src/tui/presentation.zig` check that each hint can be exceeded.
`zig build test` runs them.
The same rule in other builds, such as the search candidates and the search projection ranges, is a convention (no check).
A line check cannot follow an allocator through a parameter or a default, and the appends sit in helpers such as `Weave` methods.

## Rebuild index entries

### Rule

A rebuild index holds only the entries that a reader asks for.
`NavigationIndex.owners` holds no Line owner, because `find` resolves a Line through `spans` and every other `owners` reader asks for a ReviewCard header, a Draft header, a disclosure, or another owner that is not a Line.
Before you add entries to an index that each rebuild fills, name the code that reads them.

### Enforcement

The test "a NavigationIndex whose keys each have one span grows nothing" in `src/tui/frame.zig`, run by `zig build test`, checks that Line rows add no `owners` entry.
The `owners` build of commit `30afd1d` fails it with 4,096 entries.
The test "search projection lookups match the 6f9f09f baseline in both Layouts" in `src/tui/presentation.zig` pins every `owners` lookup in the form its readers use.
An entry without a reader in another index is a convention (no check), because a line check cannot see who reads a map entry.
Commit `8f5f069` removed visual row widths that no code read.

## Published Session content

### Rule

A published Session never changes its Diff, its Threads, or its mention names.
A change makes a new Session with a new Session Epoch through Refresh or Reconciliation.
The Buffer Search candidate key covers these inputs only by identity and the Session Epoch, and a worker that retains the Session reads them while the Presentation thread owns it.

### Enforcement

The types `[]const File`, `[]const Hunk`, `[]const Line`, `*const Comment`, and `*const MentionNames` (`Session.mention_names` in `src/tui/session.zig`) make an in-place change a compile error.
The search candidate key in `src/tui/buffer.zig` sees a field reassignment through the new address.
A `@constCast` or a field reassignment after publication is a convention (no check): test fixtures change a Session legitimately before `Presentation.init`, and no text check can see publication.

## Benchmark cell metrics

### Rule

A benchmark measures cells with the vaxis measurement that the app uses, `terminal_cell_metrics` in `src/tui/terminal_cell_metrics.zig`.
The benchmark module exports it as `tui.terminal_cell_metrics`.
`CellMetrics.bytes` counts one cell per byte, so a benchmark on it misses the grapheme cost that dominates a Buffer rebuild.
No file keeps its own copy of the vaxis adapter.

### Enforcement

`tools/check_benchmark_metrics.py`, run by `zig build test`, fails on `.bytes` or `CellMetrics.bytes` in `src/benchmark/` and `src/benchmark_buffer_search.zig`, and names the replacement.
A `.bytes =` field initializer is not a match.
`tests/check_benchmark_metrics_test.py`, also run by `zig build test`, rejects the old `visual_rows_wide_50000` and `file_tree_tallies_2000` lines of `src/benchmark/p1_actions.zig`.
A Buffer build that omits `cell_metrics` gets the `.bytes` default of `BuildOptions` in `src/tui/buffer.zig`, which the check cannot see.
That default and a second copy of the vaxis adapter are conventions (no check).

## Questions about one File

### Rule

A question about one File reads the rows that the Buffer records for that File, not every Buffer row or visual row with a `fileIndexForRow` search for each row.
`buildWithComments` in `src/tui/buffer.zig` records them in `FileRow`: `Buffer.fileHeaderRow` gives the File header and `Buffer.statusPlaceholders` gives the status placeholder rows.
A new per-File fact is a new `FileRow` field that the build sets.
A build that must visit every row walks the `file_rows` boundaries in order.
The old `selectedVersionUnavailableForFile` scanned all rows on each event while the cursor was on a File header, about 47 ms of Presentation thread CPU for each key (ticket 26).

### Enforcement

`tools/check_row_scans.py`, run by `zig build test`, counts each production `fileIndexForRow` call in the body of a `for` loop over a whole `rows` or `visual_rows` array or over `0..rows.len`, per file.
The count must equal its line in `tools/row_scan_baseline.txt`, so a new loop fails and a removed loop fails until `python3 tools/check_row_scans.py --write-baseline` lowers the baseline.
The baseline holds the 7 loops in `src/tui/presentation.zig` of 2026-11-16: two Frame builds that visit every row, the Review Search oracle, two worker searches of [ticket 28](../../.scratch/enrichment-rebuild-follow-up/issues/08-ask-the-buffer-about-one-file-in-the-worker-searches.md), and two test helpers.
`test_the_old_availability_scan_is_rejected` in `tests/check_row_scans_test.py` rejects the old loop of 6236c4c, and the other tests cover a single-statement loop, a loop over the indexes, a slice, a test block, and the baseline.
The test "yank availability keeps unavailable content within its File in both layouts and scopes" in `src/tui/presentation.zig` and the `statusPlaceholders` checks in the Status Placeholder tests of `src/tui/buffer.zig` check the answer.
A `while` loop over all rows, a call through a helper, and a scan without `fileIndexForRow`, such as `hasBodyOwner` of ticket 22, are conventions (no check).
`FileRow.status_placeholders` has no default, so a new Buffer builder must set it.

## Search range projection

### Rule

Production code gets Review Search ranges and Buffer Search ranges from the retained `SearchProjection` of the current visual rows.
It calls `SearchProjection.project`, `SearchProjection.projectRanges`, or `Published.mergeReviewRanges`.
A Review Search selection move with ranges present keeps its ranges array.
It only sets `active` in place through `markActiveSearchRanges`.
The full projection `Published.projectBufferSearchRangesFor` walks every visual row.
It builds a row index with one list for each source line.
Only tests call it, as an independent oracle.

### Enforcement

`Published.projectBufferSearchRangesFor` and `Published.projectBufferSearchRanges` in `src/tui/presentation.zig` call `@compileError` outside a test build.
A production call to either fails `zig build`, and `zig build test` too, because its CLI tests build the exe.
The `projectReviewRanges` body of commit `48e6abc` fails this way.
`selectReviewSearch` called it for each selection move.
The tests "a Review Search selection move does not walk the visual rows", "a Review Search selection move allocates nothing and keeps its ranges array", "Review Search selection moves keep source and ReviewBody ranges active in place", and "a Review Search source publication does not walk the visual rows" in `src/tui/presentation.zig`, run by `zig build test`, fail when a selection move or a source publication projects again.
A `projectRanges` call on another frequent path is a convention (no check).

## Search selection in a Buffer rebuild

### Rule

A Buffer rebuild carries no search selection.
It carries neither the Review Search selection nor the Buffer Search current occurrence.
The admission that publishes a build reads the current selection.
`Published.publishReviewRanges` marks the active Review Search ranges with `review_search.selected`.
`acceptViewBuild` maps `buffer_search.active` into the rebuilt batch with `sameSearchIndex`, and the DiffPane takes the active Buffer Search ranges from that index, not from the range flags.
So a selection move never discards a running rebuild.
A build keeps an occurrence only when it opens that occurrence.
A `.review_destination` build keeps it in `destination_occurrence`.
A build whose `Kind.opensOccurrence` holds keeps it in `destination_active`.
A `.review_destination` admission drops the build after a move to another occurrence.
No other admission compares a selection.

### Enforcement

The tests "Review Search admits an enrichment rebuild after a selection move with the current active ranges" and "Buffer Search admits an enrichment rebuild after a current occurrence move and keeps that occurrence" in `src/tui/presentation.zig`, run by `zig build test`, fail when an admission rejects or retries a build because the selection moved.
They also compare the published ranges with the full projection.
`DisclosureBuild` has no `review_selected` or `accepted_active` field.
`DisclosureBuild.create` takes no occurrence.
So the old checks `job.review_selected != published.review_search.selected` of commit `601c450` and `job.accepted_active != published.buffer_search.active` of commit `4bf740d` in `acceptViewBuild` do not compile.
The exhaustive switch in `Kind.opensOccurrence` makes each new Kind decide whether it opens an occurrence (compile error).
The test "Buffer Search rejects and retries an enrichment rebuild after its accepted batch changes" keeps the batch check.
The test "M21 authored destination cancellation rejects queued and issued work" checks that a destination build stays dropped and does not move the DiffPane.
A destination field read by a build kind that does not open an occurrence is a convention (no check) until [ticket 15](../../.scratch/enrichment-rebuild-follow-up/issues/05-carry-the-search-destination-in-the-build-kind.md) decides it.

## Search occurrence index mapping

### Rule

A search occurrence index maps into a newer batch by one of two rules.
`sameSearchIndex` in `src/tui/presentation.zig` keeps the same occurrence and gives null when the batch lost it.
A rebuild uses it, because a rebuild does not move the cursor.
So a Buffer rebuild that removes the current Buffer Search occurrence clears `buffer_search.active`, and the cursor stays.
A rebuild that removes the Buffer Search input preview clears `input.active` through `sameSearchIndex` or `sameProjectedSearchIndex`, and the cursor stays.
`nearestSearchIndex` falls back to the nearest index.
Only a move that the user asked for, such as the retry in `retryAcceptedDisclosure`, and a list selection use it.
A retried traversal move into an empty batch sets `buffer_search_no_matches` and opens nothing.

### Enforcement

`tools/check_search_index.py`, run by `zig build test`, rejects a call of any `nearest…Index` function in each function that is not in its `NEAREST` table with a reason, a second nearest call in a listed function, and a listed function that no longer calls the rule.
The old `acceptViewBuild` line of commit `7e1930b` calls `retainedSearchIndex`, which no longer exists, so it does not compile.
The test `test_the_old_admission_line_is_rejected` in `tests/check_search_index_test.py` rejects that line with the new name `nearestSearchIndex`.
The test `test_the_old_input_preview_line_is_rejected` rejects the `nearestProjectedSearchIndex` line of `acceptViewBuild` at commit `d689abc`.
The test `test_a_nearest_helper_under_a_new_name_is_rejected` rejects a nearest helper under another name.
The tests "M21 kernel Buffer Search clears the current occurrence when a Draft deletion removes it" and "M21 kernel Buffer Search retries a move into an isolated File without matches and opens nothing" in `src/tui/presentation.zig`, run by `zig build test`, fail at commit `7e1930b`.
The test "M21 kernel Buffer Search input clears its preview when a Draft deletion removes it" fails against the production code of commit `d689abc`.
The choice of rule for a new entry in `NEAREST` is a convention (no check).

## Navigation across Frames

### Rule

A navigation that outlives its Presentation Frame is a `frame.NavigationAnchor`.
It holds the cursor, its viewport offset, and the Selection mark by row identity.
Only `NavigationAnchor.resolve` against a Frame gives row numbers, so each reader resolves it against its own Frame.
The cursor restore of every admission goes through it.
The Buffer Search input holds the place where it opened as `input.start`, and no admission remaps it.
When the Frame lost that row, Escape puts the cursor at the top of the Buffer.
A `Nav` struct field sits only beside the rows of its own Frame, in `frame.Projection`, `Published`, and `ReviewProjection`.

### Enforcement

`tools/check_navigation_fields.py`, run by `zig build test`, rejects a `Nav` field in every other production container and names `NavigationAnchor`.
It reads lines through the `production` filter of `tools/check_diagnostics.py`, so a test block at any depth is not production state.
It also checks a field of a file struct, a `packed struct(u8)`, and a `union(enum(u8))`.
The test `test_the_old_input_start_and_restore_build_are_rejected` in `tests/check_navigation_fields_test.py` rejects the `saved_navigation` and `restore_navigation` fields of commit `5682c4d`, and the check fails on that tree.
The tests "M21 kernel Buffer Search input Escape returns to its start after a File Enrichment adds rows above", "M21 kernel Buffer Search input Escape returns to its start after a Draft deletion removes rows above", "M21 kernel Buffer Search input Escape returns to its start after a Draft save adds rows above", and "M21 kernel Buffer Search input Escape returns to its start after an expansion and a File Enrichment between them" in `src/tui/presentation.zig`, run by `zig build test`, fail at commit `5682c4d`.
A row number in a `usize` field, such as the old `origin` and `VersionRestoration.visual_row`, is a convention (no check), because a line check cannot tell a row number from another `usize`.
A `Nav` field whose type spans lines is also a convention.

## Row identity across Buffer builds

### Rule

A row identity that outlives a Buffer build holds no pointer into that build.
Each build makes its own Whole File gap Lines in its arena (`spliceSide` in `src/tui/buffer.zig`), so a gap Line pointer is valid in one Frame only.
A Line row identity is a `frame.LineOwner`, and `LineOwner.of` makes it.
A Hunk Line lives as long as the Session, so its identity is its pointer.
The identity of a gap Line is its File, side, and line number.
`RowOwner.line` and `SurvivingRow.line` hold a `LineOwner`.
A `*const bbr.diff.Line` field that holds a gap Line is valid only beside the rows of its own Frame, such as `VisualHalf.line` and `YankCandidates`.

### Enforcement

`RowOwner.line` and `SurvivingRow.line` have the type `LineOwner` (compile error for a Line pointer).
The tests "M21 kernel the cursor on a Whole File gap Line stays after a File Enrichment of another File", "M21 kernel the cursor on a Whole File gap Line stays after a width resize", "M21 kernel the cursor on a SideBySide Whole File gap Line stays after a File Enrichment of another File", "M21 kernel Buffer Search input Escape returns to its start on a Whole File gap Line after rebuilds", and "M21 kernel a Draft deletion puts the cursor on the next Whole File gap Line" in `src/tui/presentation.zig` fail at commit `dde803e`.
The test "M21 kernel no Line row identity of a Whole File Frame holds a gap Line pointer" fails when a visual row owner holds a gap Line in `.hunk_line`.
`zig build test` runs them.
A literal `.{ .hunk_line = line }` that bypasses `LineOwner.of` is a convention (no check).
A new `*const bbr.diff.Line` field that outlives its Frame is also a convention.
A field check cannot tell a Hunk Line from a gap Line, because both have the type `*const bbr.diff.Line`.
Every existing Line pointer field is Frame-scoped or holds only Hunk Lines.
So each existing field would be an exception.
