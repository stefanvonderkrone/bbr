# 04: Narrow the Comment Overview from the File Tree

Status: ready-for-agent
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

- [ ] The File Tree shows the root entry only while the Comment Overview shows.
- [ ] Other entries keep their depth and indent in both views.
- [ ] The root entry tally is the sum of every File tally.
- [ ] A cursor move to a File keeps only that File's items.
- [ ] A cursor move to a Directory keeps the items of every File under it.
- [ ] A cursor move to the root entry clears the filter.
- [ ] A Directory collapse that moves the cursor to the parent sets the filter to the parent.
- [ ] A Review-level item shows only without a File Tree Filter.
- [ ] "M29 overview the File Tree cursor stays on the File Tree Filter" passes after a view build and after Tab.
- [ ] `g d` hides the root entry and puts the File Tree cursor on the active File.
- [ ] `g o` puts the File Tree cursor back on the stored filter.
- [ ] Enter on a File Tree File while the Comment Overview shows moves focus to the Comment Overview.
- [ ] "M29 overview a File Jump shows the DiffPane" passes for the File Finder.
- [ ] The existing test "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" still passes.
- [ ] The filter row shows the `in <path>` chip, with a `/` at the end of a Directory path.

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
