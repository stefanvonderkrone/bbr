# 12: Drag a one-cell thumb to the last row

Status: resolved
Blocked by: none
Spec: [M30 spec](../SPEC.md)
Source: [ticket 07, finding 1](07-run-the-live-m30-outside-check.md#findings)

## Problem

A Scroll Drag that stops on the last track cell does not show the last row when the thumb is one cell long.
`dragScrollBar` in `src/tui/presentation.zig` maps the pointer cell to the first row of that cell.
When one track cell holds more rows than the track has cells, the last scroll offset is not the first row of its cell.
The drag shows the last row only when the pointer goes past the track.

## What to build

The mapping from a pointer cell to a scroll offset is the inverse of the mapping from a scroll offset to a thumb position.
A drag to the cell where the thumb of the last offset starts shows the last row.
Every scroll bar that takes a Scroll Drag uses the same mapping: the File Tree, the DiffPane, the Review Search list, and the help Overlay.

## Acceptance criteria

- [x] A Presentation test drags a one-cell thumb to its last track cell on each scroll bar and expects the last scroll offset. The test fails on the old code.
- [x] A press off the thumb on the last track cell, followed by a drag on that cell, shows the last row on each scroll bar. The test fails on the old code.
- [x] A drag to each other track cell still puts the thumb on that cell.
- [x] The live check at 30 rows on a large local Review shows the last DiffPane row and the last File Tree entry when the drag stops on the last track cell.
- [x] `zig build test`, `zig fmt --check src build.zig tests`, and `python3 tools/check_agent_docs.py` pass.

## Completion

`view.zig` owns the Scroll Drag mapping.
`view.thumbOffset` is the inverse of `view.thumb`: cell 0 gives offset 0, every other cell from the last thumb cell gives the last offset, and each other cell gives its first row.
`view.dragOffset` gives the last offset on and below the last track cell whatever the grab, and maps every other pointer through `thumbOffset`.
`dragScrollBar` in `src/tui/presentation.zig` calls `dragOffset` for the File Tree, the DiffPane, the Review Search list, and the help Overlay.

The code review found a second case of the defect.
A press off the thumb on the last track cell can grab a thumb that is one cell longer than the thumb of the last offset.
A drag on that cell then scrolled up.
`dragOffset` fixes that case.

Commits:

- `9fc49c61` files this ticket.
- `0c8b08e9` adds the failing one-cell thumb test. The old drag gives offsets 24, 120, 50, and 108 instead of 25, 145, 54, and 139 on the File Tree, the DiffPane, the Review Search list, and the help Overlay.
- `aae2ed9e` adds `view.thumbOffset` and the round-trip test.
- `a420faff` adds the failing press-and-drag test. The File Tree at 7 rows gives offset 18 instead of 25.
- `b9e2c402` adds `view.dragOffset`.

Checks:

- `zig build test-scrollbars`: 79 of 79 tests pass. With the old `cellFirstRow` drag mapping, both Presentation tests fail.
- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`, the six `tools/check_*.py` that `build.zig` runs, and `python3 tools/check_agent_docs.py`: pass.

Live check, tmux at 120 × 30, `bbr local` on a large local Review with 187,827 rows, a separate `XDG_STATE_HOME`, SGR mouse events through `tmux send-keys -l`:

- Before: a drag of the one-cell DiffPane thumb to the last track cell showed line 352 to 359 of a 468-line File, not the end. Only a drag past the track showed the last row.
- Before: a press and a drag on the last DiffPane track cell showed a row in the middle of a File.
- After: both inputs show the last row of the last File, and the same inputs on the File Tree show its last entry.
- The File Tree thumb is two cells long at 30 rows on this Review, so the File Tree did not show the defect live. The Presentation tests cover it.

Review: the Standards and Spec reviews found the press-and-drag case, a stale SPEC sentence, a weak test guard, and an AGENTS.md claim with no check. All four are fixed.
