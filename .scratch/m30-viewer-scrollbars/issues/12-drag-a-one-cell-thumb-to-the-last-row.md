# 12: Drag a one-cell thumb to the last row

Status: claimed
Claimed by: delegate session in /Volumes/Work/t3-code/m30-viewer-scrollbars
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

- [ ] A Presentation test drags a one-cell thumb to its last track cell on each scroll bar and expects the last scroll offset. The test fails on the old code.
- [ ] A drag to each other track cell still puts the thumb on that cell.
- [ ] The live check at 30 rows on a large local Review shows the last DiffPane row and the last File Tree entry when the drag stops on the last track cell.
- [ ] `zig build test`, `zig fmt --check src build.zig tests`, and `python3 tools/check_agent_docs.py` pass.
