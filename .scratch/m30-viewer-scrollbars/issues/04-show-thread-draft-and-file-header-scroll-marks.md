# 04: Show Thread, Draft, and File header Scroll Marks

Status: resolved
Blocked by: 01
Spec: [M30 spec](../SPEC.md)

## What to build

A reviewer opens a long Review with Threads and Drafts.
The DiffPane scroll bar shows a Scroll Mark for each unresolved Thread, resolved Thread, Draft, and File header.
A resolved Thread mark is dim.
A crowded cell shows its highest priority Scroll Mark.
A Scroll Mark on a thumb cell keeps its glyph in the thumb style.
The marks follow every Buffer change at once, such as a saved Draft or a disclosure toggle.

This slice defines all five mark kinds, their glyphs, and their Theme styles.
Ticket 05 adds the Buffer Search hits.

## Scope

- Add `view.ScrollMark` with `outranks`, and `view.Scrollbar.marks`.
- Add `layouts.Scroll.marks` and its copy in `layouts.bar`.
- Add `src/tui/scroll_marks.zig` with `RowMark`, `rowMarks`, and `project`.
  Add it to the test import chain in `src/main.zig`.
- Call `rowMarks` at the three places that build visual rows in `src/tui/presentation.zig`.
  Add `Published.row_marks` and `frame.Projection.row_marks`.
- Make `render.drawReview` solve the Pane tree, project the marks, and pass them in `diff_scroll`.
  In this slice, `project` receives no hits.
- Paint the marks in `view_paint.drawScrollbar` in the order of the "Painting" section of the spec.
  Add `view_paint.scrollMarkGlyph` and the glyph `comptime` check.
- Add `Theme.scrollMarkStyle` and the `comptime` checks of the "Theme" section of the spec.
- Add `┃`, `◆`, and `━` to `tools/check_box_glyphs.py`.
- Extend "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" to the marks.

## Acceptance criteria

- [x] `rowMarks` gives an `unresolved_thread` mark over the root ReviewCard and its Replies.
- [x] A Draft Reply inside a Thread gives its own `draft` mark over its own ReviewCard.
- [x] A Draft root gives a `draft` mark and no Thread mark.
- [x] An expanded resolved Thread gives a `resolved_thread` mark over its root and Replies.
- [x] A collapsed resolved Thread gives one `resolved_thread` mark on its disclosure row.
- [x] A Deleted Comment root gives an `unresolved_thread` mark.
- [x] A File header gives a `file_header` mark on its row.
- [x] A hidden Thread and a closed "Outdated" section give no mark.
- [x] A ReviewCard with a collapsed body keeps its mark.
- [x] "M30 scrollbar the mark projection puts each row range on its track cells" passes.
- [x] "M30 scrollbar a cell shows the highest priority Scroll Mark" passes for every pair of row mark kinds.
- [x] With every row fitting, the DiffPane scroll bar paints no mark.
- [x] "M30 scrollbar a Scroll Mark under the thumb keeps its glyph in the thumb style" passes.
- [x] A mark off the thumb paints its glyph in `Theme.scrollMarkStyle`.
- [x] "M30 scrollbar a section rule join leaves a Scroll Mark alone" passes.
- [x] The File Tree scroll bar paints no mark.
- [x] Each mark glyph has a cell width of 1.
- [x] An allocation failure in `project` paints the thumb without marks.
- [x] An allocation failure in `rowMarks` keeps the previous Frame.
- [x] A saved Draft and a resolved Thread toggle change the marks in the next Frame.
- [x] The build fails when a built-in Theme breaks a Scroll Mark check.
  The error names the Theme and the mark.
- [x] `tools/check_box_glyphs.py` fails on `┃`, `◆`, or `━` in `render.zig` or `app.zig` outside tests.

## Tests that prove it

- Row mark and projection fixtures in `src/tui/scroll_marks.zig`.
- Paint tests in `src/tui/view_paint.zig` and `src/tui/render.zig`.
- Frame publication tests in `src/tui/presentation.zig`.
- The Theme `comptime` block in `src/tui/theme.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`

## Completion

### Summary

- `view.ScrollMark` lists the five mark kinds. The order of its arms is the priority, and `outranks` reads it.
- `view.Scrollbar.marks` and `layouts.Scroll.marks` carry the marks. Only `layouts.Panes.diff_scroll` receives them.
- `src/tui/scroll_marks.zig` holds `RowMark`, `rowMarks`, and `project`.
  `rowMarks` walks the visual rows once and returns ranges sorted by `first`.
- The three visual row builds in `presentation.zig` call `rowMarks` with the same allocator.
  `Published.row_marks` holds the result, and `frame.Projection.row_marks` exposes it.
- `render.drawReview` solves `layouts.panes` for the window area and projects the marks with the render scratch allocator.
  An allocation failure paints the thumb without marks.
- `view_paint.drawScrollbar` takes the Theme and paints in the order of the "Painting" section.
  `view_paint.scrollMarkGlyph` holds the glyphs, and a `comptime` block checks them.
- `Theme.scrollMarkStyle` holds the styles of the spec table.
  `checkScrollMarks` in the `comptime` block after `theme.value` checks every built-in Theme.
- `tools/check_box_glyphs.py` also fails on `┃`, `◆`, and `━`.
  The AGENTS.md row of this lint names the new glyphs.
- `project` already handles Buffer Search hits.
  It uses one binary search per cell for sorted hits and one pass over the hits otherwise.
  `render.drawReview` passes no hits. Ticket 05 passes them.

### Evidence

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-scrollbars --summary all`: 65 of 65 tests pass.
- `zig build test --summary all`: 1439 of 1439 tests pass. The count after ticket 03 was 1417.
- `python3 tools/check_box_glyphs.py`: pass.
  With `const injected = "┃";`, `"◆"`, or `"━"` added outside tests to `render.zig` and `app.zig`, the lint reports both lines and exits with 1.
- The Theme check fails the build when a built-in Theme breaks it. Two temporary changes prove it:
  - `dark.status_renamed` set to the `pane_border` color gives `Theme "dark" Scroll Mark unresolved_thread must have a foreground that differs from pane_border and pane_border_focused`.
  - The `fixedTheme` Draft foreground set to blue gives `Theme "light" Scroll Mark buffer_search_hit must have a foreground that differs from Scroll Mark draft`.
- The `file_header` glyph set to `┃` gives `Scroll Mark file_header has the thumb glyph ┃ in view_paint.scrollMarkGlyph`.
- Each temporary change was reverted.

### Tests

- `src/tui/scroll_marks.zig` has the row mark fixtures for each mark kind and each hidden case.
  It also has "M30 scrollbar the mark projection puts each row range on its track cells" and "M30 scrollbar a cell shows the highest priority Scroll Mark".
- `src/tui/view_paint.zig` has "M30 scrollbar a Scroll Mark under the thumb keeps its glyph in the thumb style".
  It also tests the off-thumb style in every built-in Theme, the glyph width, and the join.
- `src/tui/render.zig` has "M30 scrollbar a section rule join leaves a Scroll Mark alone".
  It also tests the File Tree, a DiffPane whose rows fit, a projection allocation failure, and a Theme preview.
- `src/tui/presentation.zig` tests a saved Draft, a resolved Thread toggle, a Session replacement, and a `rowMarks` allocation failure.
- `src/tui/layouts.zig` extends "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" to the marks.
- The existing render thumb helpers accept a Scroll Mark glyph in the thumb style as a thumb cell.

### Defaults and notes

- The worker arena gets its memory in large chunks.
  So no allocation failure index stops the build inside `rowMarks` alone.
  The `rowMarks` failure test checks every allocation failure of `rowMarks` with `checkAllAllocationFailures`.
  It also fails each worker arena chunk and checks that the previous Frame and its row marks stay.
  `rowMarks` uses `try` in the same place as the visual rows, so its failure takes the same path.
- The glyph `comptime` check compares the marks with the two vertical thumb glyphs, because only a vertical bar has marks.

### Review

- Self-review against the spec sections "Scroll Mark kinds", "Row marks", "Projection to track cells", "Painting", and "Theme": no open finding.
- `scroll_marks.zig` imports only `buffer.zig`, `frame.zig`, and `view.zig`.
- `presentation.zig` imports neither vaxis nor `theme.zig`.

### Commit

This commit.
