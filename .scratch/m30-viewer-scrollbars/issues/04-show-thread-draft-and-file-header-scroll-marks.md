# 04: Show Thread, Draft, and File header Scroll Marks

Status: ready-for-agent
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

- [ ] `rowMarks` gives an `unresolved_thread` mark over the root ReviewCard and its Replies.
- [ ] A Draft Reply inside a Thread gives its own `draft` mark over its own ReviewCard.
- [ ] A Draft root gives a `draft` mark and no Thread mark.
- [ ] An expanded resolved Thread gives a `resolved_thread` mark over its root and Replies.
- [ ] A collapsed resolved Thread gives one `resolved_thread` mark on its disclosure row.
- [ ] A Deleted Comment root gives an `unresolved_thread` mark.
- [ ] A File header gives a `file_header` mark on its row.
- [ ] A hidden Thread and a closed "Outdated" section give no mark.
- [ ] A ReviewCard with a collapsed body keeps its mark.
- [ ] "M30 scrollbar the mark projection puts each row range on its track cells" passes.
- [ ] "M30 scrollbar a cell shows the highest priority Scroll Mark" passes for every pair of row mark kinds.
- [ ] With every row fitting, the DiffPane scroll bar paints no mark.
- [ ] "M30 scrollbar a Scroll Mark under the thumb keeps its glyph in the thumb style" passes.
- [ ] A mark off the thumb paints its glyph in `Theme.scrollMarkStyle`.
- [ ] "M30 scrollbar a section rule join leaves a Scroll Mark alone" passes.
- [ ] The File Tree scroll bar paints no mark.
- [ ] Each mark glyph has a cell width of 1.
- [ ] An allocation failure in `project` paints the thumb without marks.
- [ ] An allocation failure in `rowMarks` keeps the previous Frame.
- [ ] A saved Draft and a resolved Thread toggle change the marks in the next Frame.
- [ ] The build fails when a built-in Theme breaks a Scroll Mark check.
  The error names the Theme and the mark.
- [ ] `tools/check_box_glyphs.py` fails on `┃`, `◆`, or `━` in `render.zig` or `app.zig` outside tests.

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
