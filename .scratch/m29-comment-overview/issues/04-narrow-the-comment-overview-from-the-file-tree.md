# 04: Narrow the Comment Overview from the File Tree

Status: resolved
Blocked by: 03
Spec: [M29 spec](../SPEC.md)

## What to build

While the Comment Overview shows, the File Tree starts with an "All Files" root entry.
The File Tree cursor sets the File Tree Filter.
A File narrows the Comment Overview to that File, and a Directory narrows it to every File under it.
The root entry clears the filter.
The File Tree cursor stays on the filter and does not follow the active File.
A File Jump, such as a File Finder choice, shows the DiffPane.

## Scope

- Add `file_tree.Identity.root` and the `root_entry` parameter of `file_tree.build`.
  Paint the root entry in `drawFileTree`.
- Return `.sidebar` from `Presentation.paneContext` for the root entry.
- Set `State.file_tree_filter` on each File Tree cursor move while the Comment Overview shows.
  Copy a Directory path into the `Published` allocator.
- Add the File Tree Filter to `comment_overview.buildListing`.
- Put the File Tree cursor on the stored filter in `show_comment_overview`.
- Rebuild the File Tree without the root entry and call `revealActiveFile` in `show_diff_pane`.
- Guard `focusPane` and `revealActiveFile`, so the cursor follows the active File only while the DiffPane shows.
- Make `focus_file` and a click on a File entry move focus to the Main Pane while the Comment Overview shows.
- Support `open_file_finder` in `comment_overview`.
  A File Finder choice shows the DiffPane and runs the File Jump.
- Add the `in <path>` chip to the filter row.

## Acceptance criteria

- [x] The File Tree shows the root entry only while the Comment Overview shows.
- [x] Other entries keep their depth and indent in both views.
- [x] The root entry tally is the sum of every File tally.
- [x] A cursor move to a File keeps only that File's items.
- [x] A cursor move to a Directory keeps the items of every File under it.
- [x] A cursor move to the root entry clears the filter.
- [x] A Directory collapse that moves the cursor to the parent sets the filter to the parent.
- [x] A Review-level item shows only without a File Tree Filter.
- [x] "M29 overview the File Tree cursor stays on the File Tree Filter" passes after a view build and after Tab.
- [x] `g d` hides the root entry and puts the File Tree cursor on the active File.
- [x] `g o` puts the File Tree cursor back on the stored filter.
- [x] Enter on a File Tree File while the Comment Overview shows moves focus to the Comment Overview.
- [x] "M29 overview a File Jump shows the DiffPane" passes for the File Finder.
- [x] The existing test "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" still passes.
- [x] The filter row shows the `in <path>` chip, with a `/` at the end of a Directory path.

## Tests that prove it

- File Tree tests in `src/tui/file_tree.zig`.
- Listing fixtures in `src/tui/comment_overview.zig`.
- Presentation tests in `src/tui/presentation.zig`.
- Render tests for the root entry and the chip in `src/tui/render.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`

## Comments

- `file_tree.build` takes `root_entry` as its last parameter. `hasRootEntry` in `src/tui/presentation.zig` maps each `MainPane` to it with an exhaustive switch. Every File Tree build reads it: the start build, `stageBuffer`, `Published.stageFileTree`, and the DisclosureBuild worker.
- A DisclosureBuild records the `MainPane` at create. `DisclosureBuild.treeCurrent` refuses a job whose `MainPane`, File Tree scroll, or File Tree cursor no longer matches, and the job retries. It replaces three copies of the cursor check. An Overview destination builds its File Tree without the root entry, because it publishes the DiffPane.
- The File Tree Filter follows the File Tree cursor in `refreshOverview` at the end of each dispatch. So a key, a click, the wheel, and a Directory collapse all set it through one path.
- `rebuildOverview` copies a Directory path of the File Tree Filter into the listing arena of the same build. The path lives as long as the published listing, and `ArenaRing` frees it. No other code frees it, so no path can leak. Every Presentation test runs on `testing.allocator`.
- `comment_overview.Change.file_tree_filter` maps the root entry to no filter. So `State.file_tree_filter` never holds `.root` after a change.
- `Record.file` is the first File whose paths match the Thread root scope, as in `buffer.fileTallies`. A File entry keeps the items with that File. A Directory entry compares the scope path, as the spec says.
- `showCommentOverview` stages the File Tree and the listing and publishes both together. The stored filter places the File Tree cursor, and then the filter names the entry under the cursor. So a stored filter that the File Tree no longer shows becomes the entry that the cursor lands on.
- `revealActiveFile` and `centerActiveFile` do nothing while the Comment Overview shows. `focusPane` calls `cursorToActiveFile` only while the DiffPane shows.
- A click on the root entry moves the File Tree cursor and keeps Sidebar focus. Enter on the root entry has no default binding, because the root entry has the `sidebar` Interaction Context.
- A File Finder choice calls `showDiffPane` first. `showDiffPane` cancels a pending Overview destination. When `showDiffPane` fails, the choice stops and the Comment Overview stays.
- `open_file_finder` is now available in the `comment_overview` context and in its Command Palette. Ticket 01 asserted the opposite, so the tests "M29 overview g o and g d resolve in every Pane context and remain configurable" and "M29 overview the Command Palette lists the Main Pane Actions from every Pane" now expect it.
- The File Tree Filter chip uses the active chip style. It is the first chip, so a narrow row drops it last.
- Open: while the Comment Overview shows, the active File of the hidden DiffPane keeps the selected File Tree style and the `›` marker. So two rows can look selected. The spec does not decide this.
- Open: no test proves the `centerActiveFile` guard. The fixture File Trees fit in their viewports, so a centered scroll never hides the cursor.

## Completion

Changed paths: `src/tui/file_tree.zig`, `src/tui/comment_overview.zig`, `src/tui/presentation.zig`, `src/tui/render.zig`, `src/tui/keymap.zig`, `src/tui/list_overlay.zig`, `src/benchmark/p1_actions.zig`.

Summary: while the Comment Overview shows, the File Tree starts with the "All Files" root entry. Its tally sums every File tally. The File Tree cursor sets the File Tree Filter, and the listing keeps only the items of that File or Directory. The root entry clears the filter. `g d` hides the root entry and reveals the active File. `g o` puts the cursor back on the stored filter. Enter or a click on a File entry moves focus to the Comment Overview without a File Jump. A File Finder choice shows the DiffPane and runs the File Jump. The filter row shows the `in <path>` chip.

Tests:

- "M29 overview the root entry leads the File Tree, sums every File tally, and keeps every other depth" in `src/tui/file_tree.zig`.
- "M29 overview the File Tree Filter keeps the items of its File or of every File under its Directory" in `src/tui/comment_overview.zig`.
- "M29 overview a File Tree cursor move sets the File Tree Filter, and the root entry clears it" in `src/tui/presentation.zig`. It covers the root entry only in the Comment Overview, File, Directory, root entry, the collapse to the parent Directory, and the Review-level item.
- "M29 overview the File Tree cursor stays on the File Tree Filter" in `src/tui/presentation.zig`, after Tab, after a view build, and after a view build that starts in the DiffPane.
- "M29 overview g d hides the root entry and follows the active File, and g o restores the File Tree Filter" in `src/tui/presentation.zig`.
- "M29 overview Enter on a File Tree File while the Comment Overview shows moves focus to the Comment Overview" in `src/tui/presentation.zig`, for Enter and for clicks.
- "M29 overview a File Jump shows the DiffPane" in `src/tui/presentation.zig`, for the File Finder with a queued and an issued Overview destination.
- "M29 overview the File Tree paints the root entry and the filter row shows the File Tree Filter chip" in `src/tui/render.zig`.
- "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" still passes.

Mutation checks: each of these changes fails at least one test. Remove the `focusPane` guard, build the job File Tree without the root entry, remove the `MainPane` check in `treeCurrent`, remove the filter sync, run the File Jump for Enter in the Comment Overview, skip `showDiffPane` for a File Finder choice, keep the root entry on `g d`, or ignore the stored filter on `g o`.

Checks:

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-comment-overview`: 71/71 pass.
- `zig build test --summary all`: 1445/1445 pass (baseline 1437).
- `python3 tools/check_agent_docs.py`: pass.

Review result: the runner reviewed the `presentation.zig` diff and reran every check. The runner found no blocking issue.

Commit: see the `tui: narrow the Comment Overview from the File Tree` commit.
