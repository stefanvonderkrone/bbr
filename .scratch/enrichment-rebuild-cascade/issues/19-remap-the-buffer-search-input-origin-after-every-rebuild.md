# 19: Remap the Buffer Search input origin after every rebuild

Status: resolved
Blocked by: none

## Summary

The Buffer Search input stores the place where the user opened it as two visual row numbers: `input.saved_navigation` (a `Nav`) and `input.origin` (its cursor, the same value).
A visual row number is valid only in the Frame where it was taken.
The code must remap both numbers after each new Frame, and it does that only in two places:

- `acceptViewBuild` in `src/tui/presentation.zig`, for a `.view` or `.cache_update` build.
- `acceptBufferDisclosure`, for an `.open_input` build.

An `.enrichment`, `.draft_save`, `.draft_mutation`, or `.input` build keeps the old numbers.
When such a build adds or removes rows above the place, Escape puts the cursor at another place.

The numbers also have no fixed Frame.
`cancelBufferSearch` gives `saved_navigation` to a `.restore` build, which applies it without a change to the Frame with the saved disclosures.
`acceptBufferSearchScanned` reads `origin` against the current Frame, where an `.input` build can have expanded a disclosure above the place.
So a remap in `acceptViewBuild` for every kind is not sufficient. It remaps from the current Frame, but the number can belong to the Frame with the saved disclosures.

The fix stores the place by row identity, as the cursor restore of every rebuild already does, and resolves it in the Frame that reads it.
Then no admission needs a remap.

## Evidence

All paths are in `src/tui/presentation.zig`. The evidence is from commit `bff3397`.

### Reproduction

Throwaway tests in a detached worktree drove `Presentation`.
Each test opened the input, ran a rebuild with the input open, pressed Escape, and completed the queued work.
All 4 tests failed at `bff3397`.

| Rebuild with the input open | Setup | Place where the input opened, now | Cursor after Escape |
| --- | --- | --- | --- |
| `.enrichment` | The Whole File scope of the ticket 16 test. The cursor is on the header of File 1 (`a.txt`, row 2). Query `zz`. A File Enrichment of File 0 adds 5 rows above. | Row 7, the File 1 header | Row 2, in File 0 |
| `.draft_mutation` | `testWideSession`, 100 × 60. Draft 1 (`zz one`, line 1) and Draft 2 (`zz two`, line 3). The cursor is on the Draft 2 header (row 12). Query `zz one` moves the preview to Draft 1. `.delete_review_item` and confirm delete Draft 1. | Row 9, the Draft 2 header | Row 12, a row below Draft 2 |
| `.draft_save` | `testWideSession`, 100 × 60. `.review_comment` on row 6 and a save. The cursor moves to row 30 and the input opens with the query `added 3` before the save admission. The new Draft card adds 4 rows above. | Row 34 | Row 30, 4 rows too high |
| `.input`, then `.enrichment` | The ticket 16 session with a third File `b.txt`. The cursor is on the `b.txt` header (row 8). Query `fixed` previews the hidden Reply, and the `.input` build expands it above the place. A File Enrichment of File 1 then adds 3 rows between the Reply and `b.txt`. | Row 11, the `b.txt` header | Row 8, in File 1 (`a.txt`) |

After Escape in each case, the input is closed, the DiffPane scroll is 0, `buffer_search.active` is null, and `action_error` is null.
No message tells the user that the cursor moved.

The `.input` case shows that the stored numbers have no fixed Frame.
After the expansion, the place is row 13 in the current Frame, but `origin` is still 8.
A trial that removed the kind condition in `acceptViewBuild` fixed the first 3 cases, but the fourth case still put the cursor on row 8 in `a.txt`.
That trial remapped `saved_navigation` from the expanded Frame, where row 8 is the Reply, and the `.restore` build then applied the result to the collapsed Frame.

### Reachability

The `.enrichment` and `.input` cases are reachable by the real user.
File Enrichment runs in the background while the user types, and the preview of a hidden match expands its disclosure.

The `.draft_save` and `.draft_mutation` cases are reachable only through a direct `.action` dispatch, as the triage of [ticket 18](18-decide-the-buffer-search-input-occurrence-rule-after-a-rebuild.md) found.
The Composer, the delete confirmation, and the reanchor mode capture the keys until their Draft mutation ends.
The repo treats this state as legitimate for `Presentation`, because the test "M21 kernel Draft mutations rebuild accepted and input Buffer Search on the worker" dispatches a mutation with the input open.

A query change that loses the preview also reads `origin`: `firstSearchOccurrenceAtOrAfter(completed.navigation_rows, input.origin)` in `acceptBufferSearchScanned`.
After an expansion above the place, `origin` names an earlier row.
No probe showed a different preview from that, because through typing alone a lost preview leaves only matches that are a subset of the earlier ones. This part is inferred from the code.

## Expected behavior and its precedent

After any rebuild that the input outlives, Escape puts the cursor on the row where the user opened the input, with the same viewport offset.
A preview that a query change loses starts again from that row.

The precedent:

- Every admission already restores `published.navigation` by row identity through `frame_mod.restoreNavigationIndexed`.
- The `.view` and `.cache_update` admissions, which include a resize, already remap the input numbers by row identity. The other kinds were left out, but no comment or test gives a reason.
- The `Review recovery` rows of `AGENTS.md` restore a reading location through semantic identity, not through row indexes from an earlier Frame.

When the row is gone, the place falls back as the cursor restore does today: `restoreNavigationIndexed` gives a `Nav` at the top of the Buffer.
No reachable rebuild removes the row where the input opened. A Draft deletion behind the input is reachable only through a direct dispatch.

## Root cause

`BufferSearchInput` stores a Frame-relative value (`Nav` and `usize`) in state that lives across Frames.
Each admission must remember to remap it, and nothing records the Frame that the value belongs to.
`acceptViewBuild` remaps for two kinds, `acceptBufferDisclosure` remaps for one kind, and the `.restore` build of Escape reads the value in a third Frame.

`origin` is always equal to `saved_navigation.cursor`. Both are set together at the opening, and every remap writes both from the same input. So one fact has two copies.

## What to build

1. In `src/tui/frame.zig`, add a public type that holds a navigation by row identity, and make `restoreNavigationWith` use it:

   ```zig
   /// A navigation held by the identity of its rows, so that any later Frame of
   /// the same Session can resolve it.
   pub const NavigationAnchor = struct {
       navigation: Nav,
       cursor_row: ?VisualRow,
       mark_row: ?VisualRow,

       pub fn capture(navigation: Nav, visual_rows: []const VisualRow) NavigationAnchor { ... }
       pub fn resolve(self: NavigationAnchor, visual_rows: []const VisualRow, geometry: Geometry, index: NavigationIndex) Nav { ... }
   };
   ```

   Move the body of `restoreNavigationWith` into a private `resolveWith(self, visual_rows, geometry, index: ?NavigationIndex)`.
   `restoreNavigationWith(previous, ...)` becomes `NavigationAnchor.capture(previous.navigation, previous.visual_rows).resolveWith(...)`.
   So the cursor restore and the input place use one function.
2. In `BufferSearchInput`, replace `saved_navigation` and `origin` with one field `start: frame_mod.NavigationAnchor`, with a doc comment that says what it is, for example "Where the user opened the input. Escape returns there, and a preview that a query change loses starts again from there."
   `openBufferSearch` sets `.start = .capture(published.navigation, published.visual_rows)`.
3. Delete both remap blocks: the `if (job.kind == .view or job.kind == .cache_update)` block in `acceptViewBuild` and the `if (job.kind == .open_input)` block in `acceptBufferDisclosure`.
4. Change `DisclosureBuild.restore_navigation` to `?frame_mod.NavigationAnchor`. Only `cancelBufferSearch` and `queueQueryClearDisclosure` set it, from `input.start`.
   In `acceptBufferDisclosure`, replace the `navigation_origin` and `clear_review_disclosures` branches with one expression:

   ```zig
   published.navigation = if (job.restore_navigation) |start|
       start.resolve(job.visual_rows, job.geometry, job.projection.?.navigation)
   else
       frame_mod.restoreNavigationIndexed(previous, job.visual_rows, job.geometry, job.projection.?.navigation);
   ```

   The `restore_navigation == null` checks of ticket 16 and the copy in the retry keep their meaning.
5. Resolve `input.start` against the published Frame where the code reads the place now: `published.navigation = …` in `cancelBufferSearch` and in the query clear of `replaceBufferSearchQuery`, and the `origin` argument of `firstSearchOccurrenceAtOrAfter` in `acceptBufferSearchScanned`.
   Use `published.visual_rows`, `published.geometry`, and `published.search_projection.navigation`. The scan is admitted only when its `visual_rows_revision` is the published one, so the published Frame is the Frame of `completed.navigation_rows`.
6. Update the two benchmark readers: `benchmarkSearchSelection` reads the origin row from `input.start`, and the resize check that returns `error.AuthoredResizeMismatch` compares `input.start.resolve(...)` with the expected `Nav`.
7. Make sure that every pointer in a `VisualRow` owner lives as long as the Session, because the anchor outlives the Frame that it was captured from.
   The sketch found these owners: `diff` pointers, ids, disclosure keys, and `section.path`. The outdated section path comes from `file.displayPath()`.
8. Add a row to the rules table in `AGENTS.md`: the Buffer Search input holds the place where it opened as a `NavigationAnchor`, and no admission remaps it. Name the reproducing tests in the enforcement column.

A sketch of steps 1 to 6 in a detached worktree added about 60 production lines and removed about 50. Most of the change moves the body of `restoreNavigationWith` into `NavigationAnchor`, and the rest deletes the 3 remap blocks.
With the sketch, the 4 reproducing tests passed, and `zig build test --summary all` passed with exit 0: 54/54 steps and 1651/1651 tests.

## Acceptance criteria

- [x] Tests through `Presentation` in the `M21 kernel` group reproduce the 4 cases of the Evidence table:
  - "M21 kernel Buffer Search input Escape returns to its start after a File Enrichment adds rows above"
  - "M21 kernel Buffer Search input Escape returns to its start after a Draft deletion removes rows above"
  - "M21 kernel Buffer Search input Escape returns to its start after a Draft save adds rows above"
  - "M21 kernel Buffer Search input Escape returns to its start after an expansion and a File Enrichment between them"

  Each test finds the row of the start place in the current Frame by identity (`published.search_projection.navigation.find(row)`, or `fileHeaderRow` with `visualIndexForBufferIndex`), not by a fixed number.
  After Escape and the queued work, the cursor is on that row, `activeFile()` is the File of that row, the input is closed, and `action_error` is null.
  The first 3 tests fail at `bff3397`. The fourth test fails at `bff3397` and also with only the kind condition in `acceptViewBuild` removed.
- [x] `BufferSearchInput` has no `Nav` or row-number field. `origin` and `saved_navigation` no longer exist.
- [x] `acceptViewBuild` and `acceptBufferDisclosure` do not write the input place.
- [x] `restoreNavigationWith` and the input place use `NavigationAnchor`.
- [x] The `Review recovery` tests, the ticket 16, 17, and 18 tests, and the test "M21 authored Buffer Search opening drops old input projection after resize and scans the newest Query" pass.
- [x] `zig build test` passes. `zig fmt --check build.zig src tests` passes. `python3 tools/check_agent_docs.py` passes.

## Overlap with ticket 15

[Ticket 15](15-carry-the-search-destination-in-the-build-kind.md) asks for a `DisclosureBuild.Kind` that carries its destination.
This fix does not need ticket 15.
Ticket 16 uses `restore_navigation == null` to tell a traversal move from the other `.accepted` and `.restore` builds. This fix keeps that meaning.
If ticket 15 lands, the `.restore` and `.clear_input` payloads can carry the `NavigationAnchor`, and the null test goes away.

## Comments

### 2026-11-14, triage

Decision: `ready-for-agent`.

The defect reproduces for each of `.enrichment`, `.draft_save`, and `.draft_mutation` through `Presentation`.
A fourth case, an `.input` expansion above the place and then a File Enrichment, also reproduces. The real user can reach it.
The expected behavior has a precedent: every rebuild restores the cursor by row identity, and the `.view` and `.cache_update` admissions already remap the input place that way.
So the ticket needs no answer from a human.

The ticket first asked for a remap after every admission. A trial of that change fixed 3 cases but not the fourth, because the stored row numbers have no fixed Frame.
The ticket now asks for a row-identity anchor that each reader resolves in its own Frame.
That change deletes the 3 remap blocks and the `clear_review_disclosures` branch, and one function now restores both the cursor and the input place.

Other stored positions, surveyed in `src/tui/presentation.zig`:

| Position | State |
| --- | --- |
| The Selection mark | In `Nav`. Every admission restores it with the cursor. No gap. |
| The File Tree cursor | Held by `file_tree.Identity` (`wanted_cursor`). No gap. |
| The reanchor mode and the delete confirmation | Held by `temp_id`. No gap. |
| `mouse_press` | Guarded by the Frame revision. No gap. |
| The accepted Buffer Search | Holds disclosure keys and an occurrence index, not a row. Tickets 16 to 18 cover the index. |
| `VersionRestoration.visual_row` | A row number that can outlive a File Enrichment while `versionContentPending` holds. `versionNavigationDestination` reads it only as a tie-break distance when no exact line matches. Not confirmed. No follow-up ticket. |

Mistake class for the `correct` skill: a stored visual row number that outlives its Frame.
This ticket has two cases: `input.saved_navigation` with `input.origin`, and `DisclosureBuild.restore_navigation`, which the `.restore` build applied to a third Frame.
Ticket 16 is a related case for an occurrence index read against a newer batch.
After this fix, no long-lived state of the Buffer Search holds a row number, and the `NavigationAnchor` type makes the place Frame-independent.
A line check for a `Nav` field outside `Published.navigation` is possible, but `VersionRestoration` and the job-local rows would need exceptions. The build agent decides the level.

The probe worktree is deleted. No live run was needed.

## Completion

Commits:

- `542fc7b` adds the 4 reproducing tests.
- `b845aed` adds `frame.NavigationAnchor` and replaces `saved_navigation` and `origin` with `input.start`.
- `2813f5f` and `485de89` add `tools/check_navigation_fields.py` and its test, and the `AGENTS.md` row.
- `b8ce793` merges the two row lookups of the anchor into one helper.
- `04f1eb7` files [ticket 20](20-keep-the-cursor-on-a-whole-file-gap-line-after-a-rebuild.md).

Change:

- `NavigationAnchor` holds the count, the viewport offset of the cursor, the cursor row, and the mark row by identity.
  It holds no `Nav`, so only `resolve` against a Frame gives row numbers.
  The stored rows keep only `owner` and `source_start`, because a lookup reads only these fields.
  `restoreNavigationWith` is deleted. `restoreNavigationIndexed` and `restoreNavigation` capture and resolve an anchor.
- `DisclosureBuild.restore_navigation` is a `?frame_mod.NavigationAnchor`.
  `acceptBufferDisclosure` uses the expression of step 4. `keepPlans` stays its first statement.
- `Published.resolveNavigation` resolves an anchor against the published Frame.
  `cancelBufferSearch`, the query clear, `acceptBufferSearchScanned`, and both benchmark readers use it.
- The 3 remap blocks and the `clear_review_disclosures` navigation branch are deleted.
  The `clear_review_disclosures` field stays, because it also releases the Review Search baseline.

Checks:

- At `5682c4d`, the 4 tests fail with `expected 7, found 2`, `expected 9, found 12`, `expected 34, found 30`, and `expected 11, found 8`.
- With the kind condition in `acceptViewBuild` removed, the first 3 tests pass and the fourth test still fails with `expected 11, found 8`.
- `zig build test --summary all`: exit 0, 56/56 steps, 1651/1651 tests.
- `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_benchmark_metrics.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_search_index.py` pass.
- `tools/check_navigation_fields.py` fails on the tree of `5682c4d` at `restore_navigation` (line 2826) and `saved_navigation` (line 3972).
- Live check of the `.enrichment` case, ReleaseFast on native `aarch64-macos`, 160 × 80, with a 25 second delay in the File Enrichment worker.
  The cursor was on the header of File 1, the input was open, and the File Enrichment of File 0 moved that header from row 2 to row 75.
  At `542fc7b`, Escape put the cursor on row 2 in File 0. At `04f1eb7`, Escape put it on row 75, the File 1 header.

Review:

- Standards: no hard violation. The review found gaps in the checker patterns and long sentences in the docs. Both are fixed.
  The name `restore_navigation` stays, because tickets 15 and 16 use it.
- Spec: every reader resolves the start against its own Frame.
  Step 7 is partial. Each Buffer build makes its own Whole File gap Lines, so an anchor on a gap Line falls back to the top after a rebuild.
  The cursor restore of every admission has the same gap. Ticket 20 tracks it.
- The tests do not check the viewport offset. In the test fixtures, the whole Buffer fits in the DiffPane, so the scroll is always 0.
