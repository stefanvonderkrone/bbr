# M30 Viewer scrollbars

Status: ready-for-agent
Milestone: M30

The [M30 brief](brief.md) records the approved decisions.
This spec turns the brief and the M30 section of [TODO.md](../../TODO.md) into buildable form.
The implementation tickets live in [issues](issues/).
The layout model is [ADR-0013](../../docs/adr/0013-one-view-type-with-a-composition-union-lays-out-the-terminal.md).

## Problem Statement

In a long diff, the reviewer cannot see where they are or how much is left.
The reviewer also cannot see where the discussion is.
The File Tree and the DiffPane already declare a scroll bar in their right border.
The Review Search Results list declares one in its padding ring.
Nobody checked these scroll bars against Folds, wrapped lines, the SideBySide Layout, isolated Files, collapsed directories, resize, or content changes.
The viewer Panes have no scroll bar tests.
A scroll bar only shows a position today.
The reviewer cannot click it or drag it.

## Solution

M30 verifies the existing scroll bars, adds the missing tests, and fixes each gap that a test finds.
The thumb and the new Scroll Marks use one projection of rows to track cells.
So the thumb always covers the Scroll Mark of every visible row.

The DiffPane scroll bar shows Scroll Marks.
A Scroll Mark shows where an item sits in the Buffer.
The items are Buffer Search hits, Drafts, unresolved Threads, resolved Threads, and File headers.
A cell shows only its highest priority Scroll Mark.
A Scroll Mark on a thumb cell keeps its glyph in the thumb style.

Every scroll bar takes a press in its track and a Scroll Drag.
This includes the File Tree, the DiffPane, and the Review Search Results list.
A press off the thumb jumps to that position.
A Scroll Drag moves the thumb with the pointer.
The mouse wheel keeps working.
Paint and hit testing read the same solved View tree and the same numbers.

After the Scroll Marks ship, the user tests them by hand.
The user then decides whether bbr also needs a separate mark column.

## User Stories

Stories 1 to 18 are from the reviewer.
Stories 19 and 20 are from the maintainer.

1. I want a thumb in the File Tree border, so that I see which part of the File Tree shows.
2. I want a thumb in the DiffPane border, so that I see where I am in the Buffer.
3. I want the thumb to hide when every row fits, so that a short Buffer has a clean border.
4. I want a correct thumb with Folds, wrapped lines, and the SideBySide Layout, so that I can trust it.
5. I want the thumb to stay correct for an isolated File and for collapsed directories.
6. I want the thumb to follow a resize and a content change at once.
7. I want a Scroll Mark for each unresolved Thread, so that I find open discussion fast.
8. I want resolved Threads marked in a dim style, so that they do not compete with open Threads.
9. I want a Scroll Mark for each Draft, so that I find my unsent work before Submission.
10. I want a Scroll Mark for each Buffer Search hit of an active query, so that I see the hits.
11. I want a Scroll Mark for each File header, so that I see the File boundaries.
12. I want the most important Scroll Mark to win in a crowded cell, so that no hit or Draft hides.
13. I want a Scroll Mark to stay visible under the thumb, so that the thumb never hides a mark.
14. I want a press in the track to jump there, so that I move far in one step.
15. I want to drag the thumb, so that I move through the Buffer at my own speed.
16. I want a drag to work when the pointer leaves the track, so that I need not aim.
17. I want a drag past the track ends to reach the first and the last row.
18. I want the wheel to keep working as before.
19. I want the projection to be pure, so that tests prove it without a terminal.
20. I want paint and hit testing to share one track and one thumb, so that they never disagree.

## Decisions this spec records

The brief leaves these points to the spec.
Each item states the choice.

1. The mark priority is Buffer Search hit, Draft, unresolved Thread, resolved Thread, then File header.
   The spec confirms the proposal of the brief.
   A query is short-lived and the reviewer asked for it, so its hits come first.
   A Draft is unsent work of the reviewer, so it comes before published Threads.
2. The thumb and the Scroll Marks use one projection, `view.trackCell`.
   This changes the thumb arithmetic in `view.thumb`, because the current thumb can miss a visible row.
   The "Thumb and track" section gives a failing example.
3. A Scroll Mark marks a range of visual rows, not one row.
   A Thread mark covers the root ReviewCard and its Replies.
   A Draft mark covers the Draft's own ReviewCard.
   A Buffer Search hit mark and a File header mark cover one row.
4. The scroll bar shows no Scroll Mark when every row fits, because the thumb also hides.
5. A Buffer Search hit has a Scroll Mark only when it has a projected range in the current visual rows.
   A Search Occurrence inside a closed Fold or disclosure has no Scroll Mark.
   The current Search Occurrence has no separate mark kind.
6. Scroll Marks show only in the DiffPane scroll bar.
   The File Tree and the Review Search Results list show no Scroll Marks.
7. M30 adds no Theme field.
   `Theme.scrollMarkStyle` derives each style from existing Theme colors, with an exhaustive switch.
   The `comptime` block after `theme.value` checks every style in every built-in Theme.
8. A press in the track, off the thumb, jumps at once on the press.
   It also starts a Scroll Drag, so the reviewer can drag on without a new press.
9. A press on a scroll bar does not move the focus, as the wheel does not.
   The DiffPane cursor follows the scroll as it does for the wheel.
10. Only the Review Search Results list has an Overlay scroll bar today.
    M30 adds no scroll bar to a List Overlay, the help Overlay, or the Submission Overlay.
    A later Overlay scroll bar gets click and drag through one new arm of `frame.ScrollBar`.
11. Any key input ends a Scroll Drag.
    A wheel event, a press of another button, and a motion event without a button also end it.
12. A negative pointer coordinate in a drag or release event becomes 0.
    So a drag above the window reaches the first row, and a release outside the window ends the drag.
13. M30 adds no status part and changes no status text.

## Glossary changes

In the [Presentation glossary](../../src/tui/GLOSSARY.md):

- Add Scroll Mark:
  A sign in one cell of the DiffPane scroll bar track.
  It shows where one item sits in the Buffer.
  The item is a Buffer Search hit, a Draft, an unresolved Thread, a resolved Thread, or a File header.
  A cell shows only its highest priority Scroll Mark.
  A Scroll Mark on a thumb cell keeps its glyph in the thumb style.
  _Avoid_: marker, tick, annotation, overview ruler.
- Add Scroll Drag:
  The mouse interaction from a press on a scroll bar track to the release of that button.
  While it lasts, the pointer row sets the thumb position, also outside the track.
  _Avoid_: thumb drag, drag scroll, scrubbing.
- Change View:
  Add that its scroll bar shows a thumb over its track and takes a press and a Scroll Drag.

The other glossaries and `GLOSSARY-MAP.md` need no change.

In this spec, the track is the line of cells that holds a scroll bar.
The thumb is the run of track cells that shows the visible rows.
These are plain words, not glossary terms.

## Behavior

### Thumb and track

A scroll bar has a track of `extent` cells, a `total` row count, and an `offset`.
The offset is the first visible row.
For a vertical scroll bar, `extent` is the track height.
For every scroll bar in bbr, the track height equals the content height of its View.

`view.zig` adds two pure functions.
Every division rounds down.

```zig
/// The track cell of `row`. Requires total > extent > 0 and row < total.
pub fn trackCell(extent: u16, total: usize, row: usize) u16 {
    return @intCast(row * @as(usize, extent) / total);
}

/// The first row whose track cell is `cell`.
pub fn cellFirstRow(extent: u16, total: usize, cell: u16) usize {
    return (@as(usize, cell) * total + extent - 1) / extent;
}
```

`view.thumb(extent, total, offset)` changes to use the same projection:

```text
null when extent == 0 or total <= extent
offset' = min(offset, total - extent)
first   = trackCell(extent, total, offset')
last    = trackCell(extent, total, offset' + extent - 1)
len     = last - first + 1
```

The thumb is at least one cell.
At `offset' == 0`, the thumb starts in cell 0.
At `offset' == total - extent`, the thumb ends in cell `extent - 1`.
Every visible row has its track cell inside the thumb.

The current formula breaks the last rule.
For `extent = 7`, `total = 20`, and `offset = 6`, the current thumb covers cells 1 to 3.
Row 12 is visible, but its track cell is 4.
The new formula gives cells 2 to 4.

The existing cases in "the scroll bar thumb covers the visible share of the content" keep their results.
The length can change by one cell while the reviewer scrolls.
The test "M21 authored Review Search list shows a scroll bar for long results" computes the old length.
Ticket 01 changes it to compute the length from `view.thumb`.

### The numbers of each scroll bar

`frame.zig` adds `pub const ScrollBar = enum { sidebar, diff_pane, review_search_list };`.
`frame.scrollState(projection: Projection, bar: ScrollBar) ?ScrollState` returns the track rect, the total, and the offset.
It has an exhaustive switch on `ScrollBar`.
It returns null when the bar is not on screen, for example the Review Search list without Review Search.

| ScrollBar | Track | Total | Offset |
| --- | --- | --- | --- |
| `sidebar` | `PaneRects.sidebar_track` | `file_tree.entries.len` | `file_tree.scroll` |
| `diff_pane` | `PaneRects.diff_track` | `visual_rows.len` | `navigation.scroll` |
| `review_search_list` | `ReviewSearchGeometry.list_track` | `OverlayTarget.list_total` | `OverlayTarget.scroll` |

`frame.paneRects` reads `sidebar_track` and `diff_track` from the `track` rect of the same `layouts.panes` solve.
`frame.reviewSearchGeometry` reads `list_track` from the `track` rect of the `layouts.reviewSearch` solve.
These solves pass no scroll numbers.
The rule "A layout tree always declares its scroll bars" makes the rects equal to the painted rects.

`render.drawReview` passes the totals and offsets from `frame.scrollState` to `layouts.Panes`.
`render.drawReviewSearch` passes `ReviewSearchProjection.list_total`, which Presentation fills from the same value as `OverlayTarget.list_total`.

The Review Search list total is the result count when a result exists.
Otherwise it is the File count, because the list then shows the Files.
Today, paint uses `results.len`, the wheel uses `batch.occurrences.len`, and hit testing uses 0 while results are pending.
M30 adds one function, `Published.reviewSearchListTotal`, and paint, the wheel, hit testing, and the Scroll Drag call it.
`OverlayTarget.row_count` keeps its meaning for entry hits.

### Verification of the existing scroll bars

Ticket 01 writes a headless test for each case first.
It then fixes each case that fails.
Each case names the expected result.

1. Every row fits: the scroll bar paints nothing, and the border stays as it is.
   The track has no hit target.
2. Top: the thumb starts in cell 0.
3. Middle: the thumb covers the track cells of the first and the last visible row.
4. Bottom: the thumb ends in cell `extent - 1`.
5. An offset past `total - extent`: the thumb paints as at the bottom.
6. A track of 0 cells paints nothing, and a track of 1 cell paints one thumb cell.
7. Folds: a closed Fold counts one visual row.
   Opening it grows the total, the thumb shrinks, and the cursor row stays.
8. Wrapped lines: each wrapped row counts.
   A width change that rewraps the rows changes the total at once.
9. SideBySide Layout: the total counts the paired visual rows.
   A Layout switch changes the total and keeps the cursor row.
10. Isolated File: the total counts only the rows of that File.
    Ending the isolation restores the total of the whole Buffer.
11. Collapsed directories: the File Tree total counts the visible entries.
    A collapse near the end clamps the scroll, and the thumb ends in the last cell.
12. Resize: the track height, the content height, and `Nav.viewport` are equal at every terminal size.
    A status height change from `layouts.statusHeight` changes all three together.
13. Content change: the next Frame has the new total and offset.
    This holds for a File Enrichment result, a saved Draft, a disclosure toggle, and a Session replacement.
14. An empty Buffer and the loading state have no thumb.
15. The Sidebar track is the Sidebar's right border column.
    The DiffPane left border is the next column, and a press there is not a Sidebar scroll bar press.
16. The Review Search list total agrees between paint, the wheel, and hit testing, also while results are pending.
17. The thumb covers the track cell of every visible row, as in the example of the "Thumb and track" section.

Known gaps from the code review are cases 16 and 17.
The other cases can pass already.
A passing case keeps its new test.

### Scroll Mark kinds

`view.zig` adds this enum.
The order of the arms is the priority, from high to low.

```zig
pub const ScrollMark = enum { buffer_search_hit, draft, unresolved_thread, resolved_thread, file_header };
```

`view.ScrollMark.outranks(a, b)` returns true when `a` comes first in the enum.

| ScrollMark | Glyph | Rows of one mark |
| --- | --- | --- |
| `buffer_search_hit` | `◆` | The visual row of one projected Buffer Search range. |
| `draft` | `✎` | The visual rows of the Draft's own ReviewCard. |
| `unresolved_thread` | `●` | The visual rows of the root ReviewCard and all its Replies. |
| `resolved_thread` | `✓` | The collapsed disclosure row, or the expanded root ReviewCard and all its Replies. |
| `file_header` | `━` | The File header row. |

The glyphs `●`, `✎`, and `✓` match the File Tree tallies and the resolved Thread header.
`◆` and `━` are not line glyphs in the `view_paint` join table.
So `view_paint.join` leaves every Scroll Mark glyph as it is.
Each glyph has a cell width of 1.

### Row marks

`src/tui/scroll_marks.zig` is a new module.
It imports `buffer.zig`, `frame.zig`, and `view.zig`.
It does not import vaxis or `theme.zig`.

```zig
pub const RowMark = struct {
    kind: view.ScrollMark,
    /// The first visual row.
    first: usize,
    /// The visual row after the last one.
    end: usize,
};

pub fn rowMarks(allocator: Allocator, buffer: buffer_mod.Buffer, visual_rows: []const frame.VisualRow) ![]const RowMark;
```

`rowMarks` walks the visual rows once and returns the marks sorted by `first`.
It produces these marks:

- A `file_header` row gives one `file_header` mark.
- A `comment` row with `Part.header` at depth 0 starts a Thread mark.
  The kind is `resolved_thread` when the row has `resolved_thread` set, and `unresolved_thread` otherwise.
  The mark ends after the last visual row of the root card's subtree, from `Card.subtree_end`.
  A Deleted Comment root also starts a Thread mark.
- A `disclosure` row with `DisclosureKind.resolved_thread` gives one `resolved_thread` mark for that row.
- A `draft` row with `Part.header` starts a `draft` mark at any depth.
  The mark ends after the last visual row of that card, from `Card.rows`.
- Every other row gives no mark.

A row that the Buffer does not show gives no mark.
So a hidden Thread has no mark.
A Reply in a collapsed resolved Thread and a card in a closed "Outdated" section also have no mark.
A ReviewCard with a collapsed body keeps its mark, because its header row shows.

The three places that build visual rows also call `rowMarks` with the same allocator.
They are `Published` publication, the disclosure build, and the candidate projection in `src/tui/presentation.zig`.
`Published.row_marks` holds the result, and `frame.Projection.row_marks` exposes it.
An allocation failure fails the build in the same way as a visual row failure, so the previous Frame stays.
Paint never scans the visual rows for marks.

### Projection to track cells

```zig
pub fn project(
    allocator: Allocator,
    extent: u16,
    total: usize,
    row_marks: []const RowMark,
    hits: []const frame.ProjectedSourceRange,
    hits_sorted: bool,
) ![]const ?view.ScrollMark;
```

`project` returns one entry per track cell.
It returns an empty slice when `extent == 0` or `total <= extent`.

1. Each cell starts with no mark.
2. A row mark covers every cell from `trackCell(first)` to `trackCell(end - 1)`.
3. A cell takes a row mark when the cell is empty or the mark outranks the cell's mark.
4. A cell takes `buffer_search_hit` when a hit has a `visual_row` in the cell's rows.
   The cell's rows run from `cellFirstRow(cell)` to `cellFirstRow(cell + 1)`, or to `total` for the last cell.
   With `hits_sorted`, one binary search per cell finds the answer.
5. A hit or a row mark at or past `total` is ignored.

`render.drawReview` calls `project` with the render scratch allocator.
It passes `frame.search_ranges` only when `frame.buffer_search_ranges` is true.
Otherwise it passes no hits.
Review Search highlights in the DiffPane never give a Scroll Mark.
An allocation failure paints the scroll bar without Scroll Marks.
A Scroll Mark is decoration, so its failure never fails the Frame.

`render.drawReview` needs the track height before it paints.
It solves `layouts.panes` for the window area, as `view_paint.paint` will.
It then projects the marks and paints with them.

### Painting

`layouts.Scroll` adds `marks: []const ?view.ScrollMark = &.{}`.
`view.Scrollbar` adds the same field, and `layouts.bar` copies it.
Only `layouts.Panes.diff_scroll` receives marks.

`view_paint.drawScrollbar` takes the Theme and paints each track cell in this order:

1. Without a thumb, it paints nothing and returns.
2. A thumb cell with a mark gets the mark glyph in the thumb style.
3. A thumb cell without a mark gets the thumb glyph in the thumb style, as today.
4. A cell off the thumb with a mark gets the mark glyph in `Theme.scrollMarkStyle(mark)`.
5. A cell off the thumb without a mark keeps the border glyph.

The thumb style is `strokeStyle(theme, bar.stroke)`, as today.
`marks` has either 0 entries or one entry per track cell.
`drawScrollbar` asserts this, and it asserts that a horizontal bar has no marks.
`view_paint.scrollMarkGlyph(mark)` holds the glyph table with an exhaustive switch.
A `comptime` block checks that the five glyphs differ from each other and from both thumb glyphs.

`render.joinSectionRules` runs after `view_paint.paint` and joins rule rows into the right border.
A cell with a Scroll Mark or a thumb glyph holds no line glyph, so the join leaves it.

### Theme

`src/tui/theme.zig` adds `Theme.scrollMarkStyle(mark: view.ScrollMark) Style` with an exhaustive switch.
Each style has the background of `pane_border`.

| ScrollMark | Foreground | Emphasis |
| --- | --- | --- |
| `buffer_search_hit` | `accent` | bold |
| `draft` | `draft.fg` | bold |
| `unresolved_thread` | `status_renamed` | bold |
| `resolved_thread` | `status_added` | dim |
| `file_header` | `pane_border.fg` | none |

The `comptime` block after `theme.value` adds these checks for every built-in Theme and every `ScrollMark`:

- The style has the background of `pane_border`, so a mark never paints a band in the border.
- Every kind except `file_header` has a foreground that differs from `pane_border.fg` and `pane_border_focused.fg`.
- The four kinds other than `file_header` have four different foregrounds.
- The `resolved_thread` style is dim, and the other kinds are not dim.

The compile error names the Theme, the mark, and the failed check.
The File header mark uses the border color on purpose, because it has the lowest priority.
Its glyph tells it from the border.

### Mouse model

#### Hit targets

`frame.HitTarget` adds `scroll_bar: ScrollBarHit`.

```zig
pub const ScrollBarHit = struct { bar: ScrollBar, cell: u16 };
```

`cell` counts from the top of the track.
`frame.hitTest` returns it for a cell in a track while that scroll bar shows a thumb.
Without a thumb, the track cell has the hit result that it has today.

`frame.hitTest` checks the targets in this order:

1. With an Overlay, the Overlay captures the input as today.
   Review Search checks `list_track` before its list and Preview rects.
   Other Overlays have no scroll bar target.
2. Without an Overlay, the Selected Version targets come first, as today.
3. Then the Sidebar track and the DiffPane track.
4. Then the Pane contents, as today.

The thumb at hit time comes from `view.thumb` with the numbers of `frame.scrollState`.
So the hit target always matches the painted thumb.

#### Press

An unmodified left press on a `scroll_bar` target starts a Scroll Drag.

- On a thumb cell, the scroll does not change.
  The grab is the cell minus `thumb.first`.
- Off the thumb, the scroll jumps first.
  The new offset is `clamp(cellFirstRow(cell) - extent / 2, 0, total - extent)`.
  After the jump, the thumb covers the pressed cell.
  The grab is the cell minus the new `thumb.first`.

The press does not set `mouse_press`, so its release activates nothing.
The press clears `last_review_click` and `version_restoration`, as the wheel does.
The press does not change the focus.
A modified press on a track does nothing, as for every other target.

#### Drag

`Presentation.scroll_drag: ?ScrollDrag` holds the active Scroll Drag.

```zig
const ScrollDrag = struct {
    bar: frame_mod.ScrollBar,
    grab: u16,
    epoch: SessionEpoch,
};
```

A left drag event with an active Scroll Drag sets the scroll.
The column of the pointer does not matter.
The pointer can be over another Pane, outside the track, or past the track ends.

```text
p      = pointer row - track.y       (signed)
first  = p - grab                    (signed)
offset = 0                           when first <= 0
offset = cellFirstRow(first)         otherwise
offset = min(offset, total - extent)
```

Each drag event reads the current Frame through `frame.scrollState`.
So a content change or a resize during the drag uses the new numbers at once.
While `offset` stays inside its range, the new `thumb.first` equals `first`.
A drag event with a modifier still moves the drag.
A drag event without an active Scroll Drag clears `mouse_press`, as today.

#### Scroll paths

The new offset goes through the existing scroll path of each bar:

- `sidebar` calls `Published.sidebarScrollRows` with the difference.
  The File Tree cursor follows the edge, as for the wheel.
- `diff_pane` calls `Presentation.scrollPane(.diff, ...)` with the difference.
  The DiffPane cursor follows the edge, and `selectFocusedFileVersion` runs, as for the wheel.
  The `revealActiveFile` step in `applyMouse` keeps the File Tree cursor on the active File.
- `review_search_list` sets `review_search.list_scroll`, as the wheel does.
  The selected result does not change.

Each change increments `interaction_revision`.

#### End of a Scroll Drag

These events end a Scroll Drag:

- A left release, anywhere.
  It activates nothing.
- A motion event without a pressed button.
  This covers a release that the terminal did not report.
- A press of any button, or a wheel event.
  The event then has its normal effect.
- Any key input.
  The key then has its normal effect.
- A Session replacement, because the epoch no longer matches.
- `frame.scrollState` returns null or no thumb for the bar.
  This covers a closed Review Search, a new Overlay over a Pane bar, and content that now fits.

#### Coordinates

`app.portableMouse` drops an event with a negative column or row today.
For a drag event and a release event, it now clamps a negative coordinate to 0.
Press and motion events with a negative coordinate stay dropped.

#### What stays

- The wheel scrolls each Pane and the Review Search list as today.
- A click in a Pane content rect, a List Overlay entry, or a Review Search entry behaves as today.
- With `[input.mouse].enabled = false`, no scroll bar takes mouse input.
- While the Buffer Search input is open, `applyMouse` ignores the mouse as today.
  Any key that opens the input already ended the Scroll Drag.
- A Theme Overlay preview paints the Scroll Marks in the previewed Theme.

#### Help Overlay and README

The help Overlay mouse line becomes "click focus/select/toggle · wheel scroll · drag scroll bar".
The README mouse paragraph adds the track press and the Scroll Drag.

## Data model

- `view.ScrollMark`, `view.trackCell`, `view.cellFirstRow`, the new `view.thumb`, and `view.Scrollbar.marks`.
- `layouts.Scroll.marks`.
- `scroll_marks.RowMark`, `scroll_marks.rowMarks`, and `scroll_marks.project`.
- `frame.ScrollBar`, `frame.ScrollState`, `frame.scrollState`, `frame.ScrollBarHit`, and `HitTarget.scroll_bar`.
- `PaneRects.sidebar_track`, `PaneRects.diff_track`, `ReviewSearchGeometry.list_track`, `OverlayTarget.list_total`, and `Projection.row_marks`.
- `Published.row_marks`, `Published.reviewSearchListTotal`, and `Presentation.scroll_drag`.
- `ReviewSearchProjection.list_total`.

No SQLite table, config key, or file format changes.

## Affected modules

| Module | Change |
| --- | --- |
| `src/tui/view.zig` | `ScrollMark`, `trackCell`, `cellFirstRow`, the new `thumb`, and `Scrollbar.marks`. |
| `src/tui/layouts.zig` | `Scroll.marks` and its copy in `bar`. |
| `src/tui/view_paint.zig` | Scroll Marks and thumb overlap in `drawScrollbar`, `scrollMarkGlyph`, and the glyph `comptime` check. |
| `src/tui/scroll_marks.zig` (new) | `RowMark`, `rowMarks`, and `project`. |
| `src/tui/frame.zig` | `ScrollBar`, `scrollState`, the track rects, `HitTarget.scroll_bar`, `OverlayTarget.list_total`, and `Projection.row_marks`. |
| `src/tui/presentation.zig` | `Published.row_marks`, `reviewSearchListTotal`, `scroll_drag`, the press, drag, and end rules, and the key input end rule. |
| `src/tui/render.zig` | The numbers from `frame.scrollState`, the mark projection before paint, `list_total` in Review Search, and the help mouse line. |
| `src/tui/theme.zig` | `Theme.scrollMarkStyle` and the `comptime` checks. |
| `src/tui/app.zig` | Negative coordinate clamping in `portableMouse` for drag and release events. |
| `tools/check_box_glyphs.py` | Also fail on `┃`, `◆`, and `━` in `render.zig` and `app.zig` outside tests. |
| `src/main.zig` | Import `scroll_marks.zig` in the test chain. |
| `build.zig` | A `test-scrollbars` target with the filter `M30 scrollbar`. |
| Glossaries, `src/tui/IMPLEMENTATION.md`, `README.md`, `AGENTS.md`, `TODO.md` | Documentation changes in ticket 06. |

## AGENTS.md rules

M30 touches these existing rules:

- "Only `src/tui/view_paint.zig` paints borders, rules, junctions, Titles, and scroll bars."
  Scroll Marks are part of the scroll bar, so only `view_paint.drawScrollbar` paints them.
  `tools/check_box_glyphs.py` adds the thumb glyph `┃` and the mark glyphs `◆` and `━` to its check.
  `●`, `✎`, and `✓` stay out of the check, because File Tree tallies and Titles use them as text.
- "A layout tree always declares its scroll bars, and only the scroll numbers vary."
  M30 changes the text to "only the scroll numbers and the Scroll Marks vary".
  The rule gains a test in `src/tui/layouts.zig`.
  Its name is "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks".
  The enforcement changes from "Convention (no check)" to that test.
- "The status paints each part through `Theme.statusStyle`."
  M30 adds no status part, so the rule holds without change.
- The Theme `comptime` block after `theme.value` gains the Scroll Mark checks.
  The existing Overlay and ReviewCard checks do not change.

M30 adds these rules to the table in ticket 06:

| Rule | Enforcement |
| --- | --- |
| The thumb and every Scroll Mark come from one projection, `view.trackCell`. The thumb covers the track cell of every visible row. | The tests "M30 scrollbar the thumb covers the track cell of every visible row" and "the scroll bar thumb covers the visible share of the content" in `src/tui/view.zig`. |
| Paint, hit testing, and the Scroll Drag read the track rect from the solved View tree. They read the total and offset from `frame.scrollState`. A new scroll bar is one arm of `frame.ScrollBar`. | The exhaustive switch in `frame.scrollState` (compile error for a new arm). The test "M30 scrollbar every scroll bar hit target matches the painted thumb" in `src/tui/render.zig`. |
| A track cell shows its highest priority Scroll Mark: Buffer Search hit, Draft, unresolved Thread, resolved Thread, then File header. The order of `view.ScrollMark` is the priority. A Scroll Mark on a thumb cell keeps its glyph in the thumb style. | The tests "M30 scrollbar a cell shows the highest priority Scroll Mark" in `src/tui/scroll_marks.zig` and "M30 scrollbar a Scroll Mark under the thumb keeps its glyph in the thumb style" in `src/tui/view_paint.zig`. The glyph `comptime` block in `src/tui/view_paint.zig` (compile error). |
| Every Scroll Mark has a style in every built-in Theme with the `pane_border` background. Every kind except the File header differs from both Pane border foregrounds, and the resolved Thread mark is dim. | The `comptime` block after `theme.value` in `src/tui/theme.zig` (compile error that names the Theme and the mark). The exhaustive switch in `Theme.scrollMarkStyle`. |
| A Scroll Drag starts with a press on a track and captures every drag event until the release. The pointer column does not matter, and a pointer past a track end pins the thumb at that end. Key input, a wheel event, and a Session replacement end it. | The tests "M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends" and "M30 scrollbar key input and a Session replacement end a Scroll Drag" in `src/tui/presentation.zig`. |

## Testing Decisions

A good test asserts behavior that the reviewer can observe.
Tests assert track cells, painted glyphs and styles, published scroll offsets, cursor rows, and hit targets.
Tests do not assert private helper calls or arena layouts.

Every new test name starts with `M30 scrollbar`, so `zig build test-scrollbars` runs them.

### Seams

- `view.trackCell`, `view.cellFirstRow`, and `view.thumb` are pure arithmetic.
- `scroll_marks.rowMarks` and `scroll_marks.project` are pure.
  Fixtures build Buffers in memory, as the `buffer.zig` and `frame.zig` tests do.
- The Presentation transition is the integration seam, as in ADR-0012.
  Tests dispatch `MouseInput` and key input and inspect the Projection.
- Headless rendering is the secondary seam for glyphs and styles.

### Prior art

- "the scroll bar thumb covers the visible share of the content" in `src/tui/view.zig`.
- "a scroll bar takes the trailing cell of its ring and keeps the content rect" in `src/tui/view.zig`.
- "M21 authored Review Search list shows a scroll bar for long results" in `src/tui/render.zig`.
- "every layout places each of its Slots" in `src/tui/layouts.zig`.
- "the Panes touch with no gap and a 28-cell Sidebar" in `src/tui/layouts.zig`.
- "the painter joins a rule into its parent border and paints Titles and thumbs" in `src/tui/view_paint.zig`.
- "a join leaves text and thumbs alone" in `src/tui/view_paint.zig`.
- The `hitTest` tests in `src/tui/frame.zig`.
- The mouse click helper near line 707 of `src/tui/app.zig` and the wheel tests in `src/tui/presentation.zig`.
- The viewport tests near line 18580 of `src/tui/presentation.zig`, which compare `Nav.viewport` with the Pane content height.

### Test plan

Projection and thumb:

- "M30 scrollbar the thumb covers the track cell of every visible row".
  It checks every `extent` from 1 to 40, every `total` up to 200, and every offset.
- The thumb starts in cell 0 at the top and ends in cell `extent - 1` at the bottom.
- `cellFirstRow` is the first row whose `trackCell` is that cell.
- The example `extent = 7`, `total = 20`, `offset = 6` gives cells 2 to 4.

Existing scroll bars:

- One test for each case of the "Verification of the existing scroll bars" section, in `presentation.zig` or `render.zig`.
- "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks".
- Each bar has a track height equal to its content height.
  The test checks every size from 5 to 320 columns and from 3 to 120 rows.

Scroll Marks:

- `rowMarks` gives one mark of each kind with the specified row range.
- A Thread mark covers its Replies, and a Draft Reply inside it gives its own Draft mark.
- A collapsed resolved Thread gives one `resolved_thread` mark on its disclosure row.
- A hidden Thread and a closed "Outdated" section give no mark.
- "M30 scrollbar the mark projection puts each row range on its track cells".
- "M30 scrollbar a cell shows the highest priority Scroll Mark" covers every pair of kinds.
- A Buffer Search hit outranks every row mark in its cell.
- Hits give marks only while `buffer_search_ranges` is true.
- Review Search highlights in the DiffPane give no mark.
- A Search Occurrence inside a closed Fold gives no mark.
- With every row fitting, `project` returns no cell.
- The binary search and a linear scan give the same cells for sorted hits.

Painting and Theme:

- "M30 scrollbar a Scroll Mark under the thumb keeps its glyph in the thumb style".
- A mark off the thumb paints its glyph in `Theme.scrollMarkStyle`.
- A cell off the thumb without a mark keeps the border glyph.
- "M30 scrollbar a section rule join leaves a Scroll Mark alone".
- The File Tree and the Review Search list paint no mark.
- Each mark glyph has a cell width of 1.
- An allocation failure in `project` paints the thumb without marks.

Mouse:

- "M30 scrollbar every scroll bar hit target matches the painted thumb".
  It paints and hit-tests every track cell of each bar.
  It uses several sizes and offsets, and it covers the top, the middle, and the bottom.
- A press on the thumb keeps the scroll.
- A press off the thumb jumps, and the thumb then covers the pressed cell.
- "M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends".
  A drag by whole cells moves `thumb.first` by those cells.
  A drag past the bottom end reaches the last row, and a drag past the top end reaches row 0.
- A drag over the other Pane and over the status still moves the same bar.
- A release ends the drag and activates nothing.
- A motion event without a button ends the drag.
- "M30 scrollbar key input and a Session replacement end a Scroll Drag".
- A wheel event ends the drag and then scrolls.
- A content change during the drag uses the new total.
- A Review Search close during the drag ends it.
- A DiffPane drag moves the cursor with the edge and moves the File Tree cursor to the active File.
- A press on a Pane track does not move the focus.
- A Pane track takes no press while an Overlay is open.
- The Review Search list track takes a press and a drag.
- The Review Search list total is the same in paint, the wheel, and hit testing while results are pending.
- `portableMouse` clamps a negative drag or release coordinate to 0.
- With mouse input off, a track press does nothing.
- The wheel and the existing click tests still pass.

### Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`, and the reported test count increases.
- `python3 tools/check_agent_docs.py`

The live outside check in ticket 07 and the mark column decision in ticket 08 are manual steps.
They do not gate the hermetic suite.

## Implementation tickets

1. [Verify and fix the existing scroll bars](issues/01-verify-and-fix-the-existing-scroll-bars.md)
2. [Click and drag the Pane scroll bars](issues/02-click-and-drag-the-pane-scroll-bars.md)
3. [Click and drag the Review Search list scroll bar](issues/03-click-and-drag-the-review-search-list-scroll-bar.md)
4. [Show Thread, Draft, and File header Scroll Marks](issues/04-show-thread-draft-and-file-header-scroll-marks.md)
5. [Show Buffer Search hit Scroll Marks](issues/05-show-buffer-search-hit-scroll-marks.md)
6. [Document M30 and verify the integrated suite](issues/06-document-m30-and-verify-the-integrated-suite.md)
7. [Run the live M30 outside check](issues/07-run-the-live-m30-outside-check.md)
8. [Decide on a separate mark column](issues/08-decide-on-a-separate-mark-column.md)

## Out of Scope

- A separate mark column.
  Ticket 08 decides it, and an implementation ticket exists only if the user selects the column.
- Scroll Marks in the File Tree, the Review Search list, or the M29 Comment Overview.
- A scroll bar for a List Overlay, the help Overlay, the Submission Overlay, or the Review Search Preview.
- A horizontal scroll bar.
- A mark for a Search Occurrence that a Fold or a disclosure hides.
- A separate mark for the current Search Occurrence.
- A press on a Scroll Mark that jumps to the item of the mark.
- A hover state for the track or the thumb.
- A config key for the mark kinds or their priority.

## Further Notes

- ADR-0013 holds.
  A scroll bar still sits in a padding, border, or margin ring and never changes the content rect.
  Scroll Marks change only the paint of the track cells, so the rects do not change.
- ADR-0012 holds.
  The Scroll Drag is Presentation interaction state.
  Each drag event reads the published Frame and changes the scroll through the existing scroll paths.
- M29 adds the Comment Overview with a scroll bar in the padding ring of its entries.
  Whichever milestone lands second adds `comment_overview_entries` to `frame.ScrollBar`.
  The exhaustive switch in `frame.scrollState` forces that arm.
  The Comment Overview shows no Scroll Marks.
  The DiffPane Scroll Marks show only while the Main Pane shows the DiffPane.
  `layouts.commentOverviewPanes` shares the Sidebar View, so the Sidebar track rect does not change.
- M22 changes the weight of File Tree entries.
  It does not change the File Tree total, so the Sidebar scroll bar needs no change.
- Ticket 08 can select the mark column.
  Then the column takes one DiffPane content column left of the border scroll bar.
  The layout tree then always declares that column while it is enabled.
  The column work starts from the same `scroll_marks.project` result.
