# 03: Click and drag the Review Search list scroll bar

Status: resolved
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

- [x] "M30 scrollbar every scroll bar hit target matches the painted thumb" covers the Review Search list in landscape and portrait.
- [x] A press on the list thumb keeps `list_scroll`.
- [x] A press off the thumb jumps, and the thumb then covers the pressed cell.
- [x] A drag outside the Overlay and past both track ends reaches the first and the last result.
- [x] The selected result does not change during a press or a drag.
- [x] A press on the list track while results are pending uses the File count as the total.
- [x] A Review Search close during the drag ends it.
- [x] A click on a list entry and a double click still behave as before.

## Tests that prove it

- Hit tests in `src/tui/frame.zig`.
- Paint and hit agreement in `src/tui/render.zig`.
- Mouse transition tests in `src/tui/presentation.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`

## Completion

### Summary

- `frame.hitTest` returns a `review_search_list` scroll bar hit for a cell in `ReviewSearchGeometry.list_track`.
  It checks the track before the list and Preview rects.
  It returns the hit only while the list shows a thumb.
  Without a thumb, the track cell has the hit result that it had before.
- `frame.scrollTarget` gives the Review Search list numbers only while Review Search is the Overlay.
  Before, it trusted `frame.scrollState` alone, which keys on `OverlayTarget.review_search` and not on `OverlayTarget.kind`.
  Now hit testing and the Scroll Drag use the same Overlay check.
  The Pane bars still give no numbers under any Overlay.
- Ticket 02 already added the `review_search_list` arm of `scrollBarTo`.
  It sets `review_search.list_scroll` and leaves the selected result.
  The drag offset clamps to `total - extent`, which is the wheel maximum, because the track is as tall as the list.
- Ticket 02 already ends the Scroll Drag when `frame.scrollTarget` gives null.
  A closed Review Search gives null, so its Scroll Drag ends.
  No change in `src/tui/presentation.zig` was necessary, except tests.

### Defaults

- None. The spec decides every behavior in this ticket.

### Tests

- `src/tui/frame.zig`: "M30 scrollbar the Review Search list track takes a press before the list while it shows a thumb" is new.
  It covers landscape and portrait, the list and Preview targets, a list without a thumb, and the Pane bars under Review Search.
- `src/tui/render.zig`: "M30 scrollbar every scroll bar hit target matches the painted thumb" now also paints Review Search in landscape and portrait.
  It compares each track cell with the painted thumb at five list offsets.
- `src/tui/presentation.zig`:
  - "M30 scrollbar a press on the Review Search list thumb keeps the scroll and a press off it jumps"
  - "M30 scrollbar a Review Search list drag outside the Overlay and past both track ends reaches the first and the last result"
  - "M30 scrollbar a Review Search list press while results are pending uses the File count as the total"
  - "M30 scrollbar a Review Search close during the drag ends it"
  - "M30 scrollbar a Review Search entry click and a double click behave as before"
- The close test closes Review Search in two ways.
  Escape is key input.
  The completed disclosure build of an opened result is not input, so only the `frame.scrollTarget` check ends that Scroll Drag.

### Checks

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-scrollbars`: 43 of 43 tests pass.
- `zig build test --summary all`: 24 of 24 steps and 1417 of 1417 tests pass. The count after ticket 02 was 1411.
- `python3 tools/check_agent_docs.py`: pass.
- Native target: aarch64-macos.

### Review

- Self-review found no open finding.
- Two mutations prove the change.
  Without the track check in `frame.hitTest`, the frame test, the render test, and all five presentation tests fail.
  Without the Overlay kind check in `frame.scrollTarget`, the frame test fails.
- `OverlayTarget` can hold a `review_search` geometry with a kind other than `review_search`.
  No producer makes that state today.
  The `frame.scrollTarget` check makes hit testing and the Scroll Drag agree if a producer does.

### Commit

This commit.
