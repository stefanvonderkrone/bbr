# 05: Show Buffer Search hit Scroll Marks

Status: ready-for-agent
Blocked by: 04
Spec: [M30 spec](../SPEC.md)

## What to build

A reviewer types a Buffer Search query.
The DiffPane scroll bar shows a Scroll Mark for each hit that has a row in the Buffer.
A hit mark outranks every other Scroll Mark in its cell.
The marks change with each edit of the query.
When the query ends, the hit marks go away, and the other marks return.
Review Search highlights in the DiffPane give no Scroll Mark.

## Scope

- Pass `frame.search_ranges` to `scroll_marks.project` only when `frame.buffer_search_ranges` is true.
- Find the hits of each cell with one binary search when `search_ranges_sorted` is true.
  Scan the hits when they are not sorted.

## Acceptance criteria

- [ ] A Buffer Search hit in a source Line gives a `buffer_search_hit` mark in its cell.
- [ ] A Buffer Search hit in a ReviewBody gives a `buffer_search_hit` mark in its cell.
- [ ] A hit mark outranks a Draft, a Thread, and a File header mark in the same cell.
- [ ] A Search Occurrence inside a closed Fold gives no mark.
- [ ] An edit of the query changes the hit marks in the next Frame.
- [ ] Clearing the query removes every hit mark and keeps the row marks.
- [ ] Review Search highlights in the DiffPane give no mark.
- [ ] The binary search and a linear scan give the same cells for sorted hits.
- [ ] A hit at or past the total is ignored.

## Tests that prove it

- Projection fixtures in `src/tui/scroll_marks.zig`.
- Buffer Search transition and paint tests in `src/tui/presentation.zig` and `src/tui/render.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`
