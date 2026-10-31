# 05: Show Buffer Search hit Scroll Marks

Status: resolved
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

- [x] A Buffer Search hit in a source Line gives a `buffer_search_hit` mark in its cell.
- [x] A Buffer Search hit in a ReviewBody gives a `buffer_search_hit` mark in its cell.
- [x] A hit mark outranks a Draft, a Thread, and a File header mark in the same cell.
- [x] A Search Occurrence inside a closed Fold gives no mark.
- [x] An edit of the query changes the hit marks in the next Frame.
- [x] Clearing the query removes every hit mark and keeps the row marks.
- [x] Review Search highlights in the DiffPane give no mark.
- [x] The binary search and a linear scan give the same cells for sorted hits.
- [x] A hit at or past the total is ignored.

## Tests that prove it

- Projection fixtures in `src/tui/scroll_marks.zig`.
- Buffer Search transition and paint tests in `src/tui/presentation.zig` and `src/tui/render.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`

## Completion

### Summary

- `render.drawReview` passes `frame.search_ranges` to `scroll_marks.project` only when `frame.buffer_search_ranges` is true.
  It passes `frame.search_ranges_sorted` as `hits_sorted`.
  Otherwise it passes no hits, so Review Search highlights give no Scroll Mark.
- Ticket 04 already made `project` handle hits.
  It uses one binary search per cell for sorted hits and one pass over the hits otherwise.
- The new `render.zig` tests drive a real Buffer Search through the Presentation and paint the Frame headless.
  The helper `expectHitMarks` checks each DiffPane track cell.
  A cell paints a hit mark when a published range has a row in it. Otherwise the cell paints its row mark.
- `testRawSession` builds a Session from a raw diff and Comments.
  `testScrollSession` now calls it.

### Evidence

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-scrollbars --summary all`: 70 of 70 tests pass.
- `zig build test --summary all`: 1444 of 1444 tests pass. The count after ticket 04 was 1439.
- Two temporary changes to the gate in `render.drawReview` prove the tests:
  - With no hits, the source Line and ReviewBody test, the query edit test, and the Fold test fail.
  - With `frame.search_ranges` always passed, the Review Search test fails.
- Each temporary change was reverted.

### Tests

- "M30 scrollbar a Buffer Search hit in a source Line and in a ReviewBody outranks the row marks of its cell" covers a source Line, a Comment ReviewBody, and a Draft ReviewBody.
  The Thread and Draft cells have those row marks without the hits, and they paint the hit mark.
- "M30 scrollbar a cell shows the highest priority Scroll Mark" from ticket 04 proves that a hit outranks every row mark, the File header mark included.
- "M30 scrollbar a query edit changes the hit marks and clearing the query keeps the row marks" edits `line 1` to `line 15` and then clears the query.
- "M30 scrollbar a Search Occurrence inside a closed Fold gives no mark" has two occurrences in two Folds.
  Buffer Search opens only the Fold of the active occurrence, so one hit mark shows.
- "M30 scrollbar Review Search highlights in the DiffPane give no mark" paints a Frame with Review Search ranges.
- "M30 scrollbar the binary search and a linear scan give the same hit cells" from ticket 04 covers sorted hits, also hits past the total.
- "M30 scrollbar the projection ignores a hit at or past the total" is new in `src/tui/scroll_marks.zig`.

### Review

- Self-review of the diff found one issue.
  The first test helper started enrichment twice on one Session. `testRawSession` fixed it.
- No new mistake class. AGENTS.md needs no new rule.

### Defaults and notes

- All Buffer Search tests are in `src/tui/render.zig`, because only paint shows a Scroll Mark.
  `src/tui/presentation.zig` does not import the painter.

### Commits

- This commit.
