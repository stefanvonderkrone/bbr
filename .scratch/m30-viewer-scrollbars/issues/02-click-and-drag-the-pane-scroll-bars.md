# 02: Click and drag the Pane scroll bars

Status: ready-for-agent
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

- [ ] "M30 scrollbar every scroll bar hit target matches the painted thumb" passes for the Sidebar and the DiffPane at several sizes and offsets.
- [ ] A track without a thumb gives the same hit result as before M30.
- [ ] A press on the thumb keeps the scroll.
- [ ] A press off the thumb jumps, and the thumb then covers the pressed cell.
- [ ] "M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends" passes for both Panes.
- [ ] A drag by whole cells moves `thumb.first` by those cells.
- [ ] A drag past the bottom end reaches the last row.
- [ ] A drag past the top end reaches row 0.
- [ ] A drag over the other Pane and over the status still moves the same bar.
- [ ] A release ends the drag and activates nothing.
- [ ] A motion event without a button ends the drag.
- [ ] "M30 scrollbar key input and a Session replacement end a Scroll Drag" passes.
- [ ] A wheel event ends the drag and then scrolls.
- [ ] A content change during the drag uses the new total.
- [ ] A DiffPane drag moves the cursor with the edge.
- [ ] During a DiffPane drag, the File Tree cursor follows the active File.
- [ ] A press on a Pane track does not move the focus.
- [ ] A Pane track takes no press while an Overlay is open.
- [ ] A press on the DiffPane left border column is not a Sidebar scroll bar press.
- [ ] `portableMouse` clamps a negative drag or release coordinate to 0 and still drops a negative press.
- [ ] With mouse input off, a track press does nothing.
- [ ] The existing click and wheel tests still pass.

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
