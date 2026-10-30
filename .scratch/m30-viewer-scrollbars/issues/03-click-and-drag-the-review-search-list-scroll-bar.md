# 03: Click and drag the Review Search list scroll bar

Status: ready-for-agent
Blocked by: 02
Spec: [M30 spec](../SPEC.md)

## What to build

A reviewer opens Review Search with many results.
A press on the Results list track jumps or grabs the thumb, as in the Panes.
A Scroll Drag moves the list, also outside the Overlay and past the track ends.
The selected result does not change.
Closing Review Search ends the Scroll Drag.

## Scope

- Make `frame.hitTest` return `HitTarget.scroll_bar` for `ReviewSearchGeometry.list_track` before the list and Preview rects.
- Add the `review_search_list` arm to the Scroll Drag scroll path.
  It sets `review_search.list_scroll`, clamped as the wheel clamps it.
- End the Scroll Drag when `frame.scrollState` returns null for the bar.

## Acceptance criteria

- [ ] "M30 scrollbar every scroll bar hit target matches the painted thumb" covers the Review Search list in landscape and portrait.
- [ ] A press on the list thumb keeps `list_scroll`.
- [ ] A press off the thumb jumps, and the thumb then covers the pressed cell.
- [ ] A drag outside the Overlay and past both track ends reaches the first and the last result.
- [ ] The selected result does not change during a press or a drag.
- [ ] A press on the list track while results are pending uses the File count as the total.
- [ ] A Review Search close during the drag ends it.
- [ ] A click on a list entry and a double click still behave as before.

## Tests that prove it

- Hit tests in `src/tui/frame.zig`.
- Paint and hit agreement in `src/tui/render.zig`.
- Mouse transition tests in `src/tui/presentation.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`
