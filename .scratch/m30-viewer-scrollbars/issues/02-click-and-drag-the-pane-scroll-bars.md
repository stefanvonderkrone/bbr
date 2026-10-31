# 02: Click and drag the Pane scroll bars

Status: resolved
Blocked by: 01
Spec: [M30 spec](../SPEC.md)

## What to build

A reviewer presses the File Tree or the DiffPane scroll bar track.
A press on the thumb grabs it.
A press off the thumb jumps there, and the thumb then covers the pressed cell.
The reviewer drags, and the thumb follows the pointer row.
The drag keeps working over the other Pane, over the status, and past the track ends.
A drag past an end reaches the first or the last row.
The release ends the Scroll Drag and activates nothing.
The wheel works as before.

## Scope

- Add `frame.ScrollBarHit` and `HitTarget.scroll_bar`.
  `frame.hitTest` returns it for the Sidebar and DiffPane tracks while the bar shows a thumb.
  Keep the hit order of the "Hit targets" section of the spec.
- Add `Presentation.scroll_drag` and the press, drag, and end rules of the "Mouse model" section.
- Route each new offset through `Published.sidebarScrollRows` or `Presentation.scrollPane`.
- End a Scroll Drag on key input, a wheel event, another press, and a motion event without a button.
  Also end it on a Session replacement and when the thumb goes away.
- Clamp a negative coordinate of a drag or release event to 0 in `app.portableMouse`.
- Change the help Overlay mouse line to "click focus/select/toggle · wheel scroll · drag scroll bar".

## Acceptance criteria

- [x] "M30 scrollbar every scroll bar hit target matches the painted thumb" passes for the Sidebar and the DiffPane at several sizes and offsets.
- [x] A track without a thumb gives the same hit result as before M30.
- [x] A press on the thumb keeps the scroll.
- [x] A press off the thumb jumps, and the thumb then covers the pressed cell.
- [x] "M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends" passes for both Panes.
- [x] A drag by whole cells moves `thumb.first` by those cells.
- [x] A drag past the bottom end reaches the last row.
- [x] A drag past the top end reaches row 0.
- [x] A drag over the other Pane and over the status still moves the same bar.
- [x] A release ends the drag and activates nothing.
- [x] A motion event without a button ends the drag.
- [x] "M30 scrollbar key input and a Session replacement end a Scroll Drag" passes.
- [x] A wheel event ends the drag and then scrolls.
- [x] A content change during the drag uses the new total.
- [x] A DiffPane drag moves the cursor with the edge.
- [x] During a DiffPane drag, the File Tree cursor follows the active File.
- [x] A press on a Pane track does not move the focus.
- [x] A Pane track takes no press while an Overlay is open.
- [x] A press on the DiffPane left border column is not a Sidebar scroll bar press.
- [x] `portableMouse` clamps a negative drag or release coordinate to 0 and still drops a negative press.
- [x] With mouse input off, a track press does nothing.
- [x] The existing click and wheel tests still pass.

## Tests that prove it

- Hit tests in `src/tui/frame.zig`.
- Paint and hit agreement in `src/tui/render.zig`.
- Mouse transition tests in `src/tui/presentation.zig`.
- The `portableMouse` test in `src/tui/app.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`

## Completion

### Summary

- `frame.ScrollBarHit` and `HitTarget.scroll_bar` are new.
  `frame.hitTest` returns a scroll bar hit for the Sidebar and DiffPane tracks after the Selected Version targets and before the Pane contents.
- `frame.scrollTarget` is new.
  It gives the numbers of a bar only while no Overlay covers the bar and the bar shows a thumb.
  Hit testing and the Scroll Drag both use it.
  `frame.scrollState` still gives the Pane numbers under an Overlay, because paint needs them.
- `Presentation.scroll_drag` holds a `ScrollDrag` with `bar`, `grab`, and `epoch`.
  `pressScrollBar` grabs the thumb or jumps first.
  `dragScrollBar` reads the current Frame on each drag event and ends the Scroll Drag on an epoch mismatch or when `frame.scrollTarget` gives null.
  `scrollBarTo` switches exhaustively on `frame.ScrollBar` and sends each offset through `Presentation.scrollPane`.
  Its `review_search_list` arm sets `review_search.list_scroll`, but hit testing does not return that bar until ticket 03.
- `applyMouse` ends the Scroll Drag on every event except a left drag.
  A left release then does nothing more.
  `dispatch` ends it on `.key` and `.action` input.
- `app.portableMouse` clamps a negative drag or release coordinate to 0 and still drops a negative press or motion.
- The help Overlay mouse line is "click focus/select/toggle · wheel scroll · drag scroll bar".

### Defaults

- A wheel event on a track does nothing, as before M30.
  The track was a border cell without a hit target, and the spec keeps the wheel as it is.

### Tests

- `src/tui/frame.zig`: "M30 scrollbar the Sidebar track is the Sidebar border and the next column is the DiffPane border" now expects a Sidebar scroll bar hit on each track cell.
  "M30 scrollbar a track without a thumb or under an Overlay has no scroll bar target" is new.
- `src/tui/render.zig`: "M30 scrollbar every scroll bar hit target matches the painted thumb" and "M30 scrollbar the help Overlay mouse line names the scroll bar drag".
- `src/tui/presentation.zig`: "M30 scrollbar a press on the thumb keeps the scroll and a press off the thumb jumps under the pointer", "M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends", "M30 scrollbar key input and a Session replacement end a Scroll Drag", "M30 scrollbar a release activates nothing and a motion, a wheel, or another press ends a Scroll Drag", "M30 scrollbar a Scroll Drag uses the new total after a content change", "M30 scrollbar a DiffPane drag moves the cursor with the edge and the File Tree cursor to the active File", "M30 scrollbar a Pane track takes no press under an Overlay, on the DiffPane border, or with mouse input off", and "M30 scrollbar a Scroll Drag ends when its thumb goes away".
- `src/tui/app.zig`: "M30 scrollbar portableMouse clamps a negative drag or release coordinate and drops a negative press".

### Checks

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-scrollbars`: 37 of 37 tests pass.
- `zig build test --summary all`: 24 of 24 steps and 1411 of 1411 tests pass. The count after ticket 01 was 1399.
- `python3 tools/check_agent_docs.py`: pass.
- Native target: aarch64-macos.

### Review

- Self-review found no open finding.
- Two mutations prove the end rules. Without the key rule or the epoch check, "M30 scrollbar key input and a Session replacement end a Scroll Drag" fails.
- `presentation.zig` imports `view.zig`, which imports only `std`. It imports neither vaxis nor `theme.zig`.

### Commit

This commit.
