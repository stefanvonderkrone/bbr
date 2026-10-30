# 01: Verify and fix the existing scroll bars

Status: ready-for-agent
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

- [ ] "M30 scrollbar the thumb covers the track cell of every visible row" passes for every `extent` from 1 to 40, every `total` up to 200, and every offset.
- [ ] The example `extent = 7`, `total = 20`, `offset = 6` gives a thumb on cells 2 to 4.
- [ ] "the scroll bar thumb covers the visible share of the content" passes without a change to its cases.
- [ ] The thumb starts in cell 0 at the top and ends in cell `extent - 1` at the bottom.
- [ ] Each of the 17 verification cases of the spec has a passing test.
- [ ] Each bar has a track height equal to its content height.
  The test covers 5 to 320 columns and 3 to 120 rows.
- [ ] After a resize and after a status height change, the DiffPane track height equals `Nav.viewport`.
  The Sidebar track height equals the File Tree viewport.
- [ ] Paint, the wheel, and `OverlayTarget.list_total` use the same Review Search list total.
  This also holds while results are pending.
- [ ] "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" passes for `layouts.panes` and `layouts.reviewSearch` with different scroll numbers.
- [ ] "every layout places each of its Slots" still passes.

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
