# 01: Verify and fix the existing scroll bars

Status: resolved
Blocked by: none
Spec: [M30 spec](../SPEC.md)

## What to build

The File Tree, the DiffPane, and the Review Search list show a correct thumb in every case of the spec.
The thumb hides when every row fits.
The thumb covers the track cell of every visible row.
Paint and the hit test geometry read the same track rect and the same numbers.

This slice adds no Scroll Mark and no new mouse behavior.
It prepares the projection and the numbers that tickets 02 to 05 use.

## Scope

- Add `view.trackCell` and `view.cellFirstRow` to `src/tui/view.zig`.
  Change `view.thumb` to use them, as the "Thumb and track" section of the spec describes.
- Add `frame.ScrollBar`, `frame.ScrollState`, and `frame.scrollState` with an exhaustive switch.
- Add `PaneRects.sidebar_track`, `PaneRects.diff_track`, and `ReviewSearchGeometry.list_track`.
  Read each one from the `track` rect of the existing solve.
- Add `Published.reviewSearchListTotal`, `OverlayTarget.list_total`, and `ReviewSearchProjection.list_total`.
  Make paint and the wheel use it.
- Make `render.drawReview` read the Pane totals and offsets from `frame.scrollState`.
- Write one headless test for each case of the "Verification of the existing scroll bars" section first.
  Then fix each case that fails.
- Update "M21 authored Review Search list shows a scroll bar for long results" to compute the thumb length from `view.thumb`.
- Add the test "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" for the numbers.
  Ticket 04 extends it to the Scroll Marks.
- Add the `test-scrollbars` build target with the filter `M30 scrollbar`.

## Acceptance criteria

- [x] "M30 scrollbar the thumb covers the track cell of every visible row" passes for every `extent` from 1 to 40, every `total` up to 200, and every offset.
- [x] The example `extent = 7`, `total = 20`, `offset = 6` gives a thumb on cells 2 to 4.
- [x] "the scroll bar thumb covers the visible share of the content" passes without a change to its cases.
- [x] The thumb starts in cell 0 at the top and ends in cell `extent - 1` at the bottom.
- [x] Each of the 17 verification cases of the spec has a passing test.
- [x] Each bar has a track height equal to its content height.
  The test covers 5 to 320 columns and 3 to 120 rows.
- [x] After a resize and after a status height change, the DiffPane track height equals `Nav.viewport`.
  The Sidebar track height equals the File Tree viewport.
- [x] Paint, the wheel, and `OverlayTarget.list_total` use the same Review Search list total.
  This also holds while results are pending.
- [x] "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" passes for `layouts.panes` and `layouts.reviewSearch` with different scroll numbers.
- [x] "every layout places each of its Slots" still passes.

## Tests that prove it

- Projection tests in `src/tui/view.zig`.
- Layout tests in `src/tui/layouts.zig`.
- Geometry tests in `src/tui/frame.zig`.
- Verification tests in `src/tui/presentation.zig` and `src/tui/render.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`

## Completion

### Summary

- `view.trackCell` and `view.cellFirstRow` project rows to track cells.
  `view.thumb` now runs from the track cell of the first visible row to the track cell of the last visible row.
- `frame.ScrollBar`, `frame.ScrollState`, and `frame.scrollState` give the track, the total, and the offset of each scroll bar.
  The switch in `frame.scrollState` is exhaustive.
- `PaneRects.sidebar_track`, `PaneRects.diff_track`, and `ReviewSearchGeometry.list_track` come from the `track` rect of the existing solves.
- `Published.reviewSearchListTotal` is the one Review Search list total.
  `OverlayTarget.list_total`, `ReviewSearchProjection.list_total`, the wheel, the keyboard scroll, and the scan clamp use it.
  `ReviewSearchProjection.list_total` has no default, so each constructor must pass it.
- `render.drawReview` reads the Pane totals and offsets from `frame.scrollState`.
- The `test-scrollbars` build step runs the tests whose names start with `M30 scrollbar`.

### Verification cases

| Case | Test | Before the fix |
| --- | --- | --- |
| 1 | "M30 scrollbar a Pane whose rows fit paints no thumb and keeps its border" in `render.zig`. "M30 scrollbar the Sidebar track is the Sidebar border and the next column is the DiffPane border" in `frame.zig` checks that the track has no hit target. | Pass |
| 2 to 5 | "M30 scrollbar the DiffPane thumb paints at the top, the middle, the bottom, and past the bottom" in `render.zig`. "M30 scrollbar the thumb covers the track cell of every visible row" in `view.zig`. | Pass in `render.zig` |
| 6 | "M30 scrollbar a track of no cells paints nothing and a track of one cell paints one thumb cell" in `render.zig` and "M30 scrollbar a track of no cells has no thumb and a track of one cell has one thumb cell" in `view.zig`. | Pass |
| 7 | "M30 scrollbar a closed Fold counts one row and opening it grows the total under the cursor" in `presentation.zig`. | Pass |
| 8 | "M30 scrollbar a width change that rewraps the rows changes the total at once" in `presentation.zig`. | Pass |
| 9 | "M30 scrollbar a Layout switch counts the paired rows and keeps the cursor row" in `presentation.zig`. | Fail. The old thumb missed the cursor row. The case 17 fix fixes it. |
| 10 | "M30 scrollbar an isolated File counts only its rows and ending the isolation restores the total" in `presentation.zig`. | Pass |
| 11 | "M30 scrollbar a collapse near the end of the File Tree clamps the scroll to the last cell" in `presentation.zig`. | Pass |
| 12 | "M30 scrollbar every track is as tall as the content of its View at every size" in `frame.zig`, "M30 scrollbar each track is as tall as Nav.viewport after every resize" in `presentation.zig`, and "M30 scrollbar a status height change keeps each track as tall as its viewport" in `app.zig`. | Fail in `presentation.zig`. The old thumb missed the cursor row. The case 17 fix fixes it. |
| 13 | "M30 scrollbar the next Frame has the new total after each content change" in `presentation.zig`. It covers a disclosure toggle, a Session replacement, a saved Draft, and a File Enrichment result. | Pass |
| 14 | "M30 scrollbar an empty Buffer and the loading state have no thumb" in `presentation.zig`. | Pass |
| 15 | "M30 scrollbar the Sidebar track is the Sidebar border and the next column is the DiffPane border" in `frame.zig`. | Pass |
| 16 | "M30 scrollbar paint, the wheel, and hit testing share the Review Search list total while results are pending" in `presentation.zig`. | Fail. While results were pending, the wheel used the old result count, but paint used the File count. `Published.reviewSearchListTotal` fixes it. |
| 17 | "M30 scrollbar the thumb covers the visible row that the old formula missed" in `view.zig` and "M30 scrollbar the painted thumb covers the track cell of every visible row" in `view_paint.zig`. | Fail. The new `view.thumb` formula fixes it. |

The "Before the fix" column comes from a run of the new tests in a temporary copy.
That copy had the old `view.thumb` formula and the old wheel total.

Other tests:

- "M30 scrollbar the first row of a cell projects to that cell" in `view.zig`.
- "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" in `layouts.zig`.
  It checks the scroll numbers only. Ticket 04 adds the Scroll Marks.
- "M21 authored Review Search list shows a scroll bar for long results" in `render.zig` now computes the thumb from `view.thumb`.

### Checks

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-scrollbars --summary all`: 25 of 25 tests pass.
- `zig build test --summary all`: 24 of 24 steps succeed, and 1399 of 1399 tests pass. The baseline was 1378.
- `python3 tools/check_agent_docs.py`: pass.

The native target is `native-macos.15.0`.

### Review

The self-review found no open issue.
Paint and the hit test geometry read the same track rects.
The Review Search list total has one owner.
No test starts the app or sends a request to Bitbucket.

### Commit

This commit.
