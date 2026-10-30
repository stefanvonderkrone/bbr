# M30 Viewer scrollbars: brief

Status: ready-for-agent
Milestone: M30

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M30.
The requirements live in the M30 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Presentation glossary](../../src/tui/GLOSSARY.md).
The layout model is [ADR-0013](../../docs/adr/0013-one-view-type-with-a-composition-union-lays-out-the-terminal.md).

## In my own words

In a long diff, the reviewer cannot see where they are, how much is left, or where the discussion is.
A scroll bar answers the first two questions.
Marks in the scroll bar answer the third: they show where Threads, Drafts, search hits, and File starts are.
Click and drag make the scroll bar a fast way to move, not only a display.

## Current state

The View-layout work (PR #14) already declares scroll bars for both viewer Panes.
`render.zig` passes the File Tree `entries` and `scroll`, and the DiffPane `visual_rows` and `navigation.scroll`, to `layouts.Panes`.
`view.thumb` sizes and places the thumb, and `view_paint` paints it in the border column.
The Review Search list has a scroll bar test.
The viewer Panes have no M30 tests yet, and nobody checked the edge cases.

## Expert approach

- Prior art: the overview ruler in VS Code and the scroll bar marks in JetBrains IDEs.
  Both put marks for problems, changes, and search hits in the scroll bar track and keep them visible under the thumb.
- Method: the marks are a projection of the Buffer rows into the track height.
  The projection is pure and testable without a terminal.
  The scroll bar stays declared in every layout tree, as the AGENTS.md rule requires.
  Only the numbers and the marks vary.
- Outside check: on the largest benchmark PullRequest from M28 (`pr-webapp` #14, 593 Files), compare each mark position with the real row of its Thread, Draft, hit, or File header.
  Then drag the thumb from top to bottom and confirm that the DiffPane reaches the first and the last row.
  Repeat in a terminal with 30 rows and in one with 80 rows.

## Decisions

The user made these decisions on 2026-10-30.

1. **M30 verifies the existing scroll bars, adds the tests, and fixes the gaps.**
   The check covers Folds, wrapped lines, the SideBySide Layout, isolated Files, collapsed File Tree directories, resize, and content changes.
2. **The DiffPane scroll bar shows marks.**
   The marks show unresolved Threads, resolved Threads (dimmed), Drafts, Buffer Search hits while a query is active, and File headers.
3. **A mark on a thumb cell keeps its glyph in the thumb style.**
   Both the mark and the thumb stay visible.
4. **Every scroll bar takes click and drag.**
   This includes the File Tree, the DiffPane, the Review Search list, and every other Overlay with a scroll bar.
   A click in the track jumps to that position.
   Dragging the thumb scrolls.
   The mouse wheel keeps working.
5. **The mark column is a later decision after a hands-on test.**
   M30 first ships the marks in the scroll bar track.
   The user then tests the track variant and decides whether bbr also needs a separate mark column next to the scroll bar.
   If the user wants the column, it takes one DiffPane content column left of the border scroll bar.
   The layout tree always declares that column when it is enabled, so the geometry does not change between hit testing and paint.

## Specification changes

- Changed: M30 grows from S/M to M because of the marks and the mouse work.
- Added: the marks (decisions 2 and 3).
  Several marks can fall on one cell.
  The proposed priority is Buffer Search hit, Draft, unresolved Thread, resolved Thread, then File header.
  `SPEC.md` confirms it.
- Added: each mark kind needs a Theme style in every built-in Theme.
  The `comptime` Theme check must cover the new styles.
- Added: click and drag on every scroll bar (decision 4).
  Hit testing uses the same solved View tree as paint, so a thumb position never differs between paint and mouse input.
- Added: a `ready-for-human` checkpoint ticket after the track marks ship.
  The user tests the track variant and decides on the separate mark column (decision 5).
  A column implementation ticket exists only if the user selects the column.
- Kept: the thumb hides when every row fits.
  Kept: headless tests for thumb size and position at the top, middle, and bottom, and after resize and content changes.
  Added tests: the mark projection, mark priority, marks under the thumb, click, drag, and drag past the track ends.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the implementation tickets in this directory.
