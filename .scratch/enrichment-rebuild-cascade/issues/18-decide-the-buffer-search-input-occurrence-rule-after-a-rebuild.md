# 18: Decide the Buffer Search input occurrence rule after a rebuild

Status: ready-for-agent
Blocked by: none

## Summary

[Ticket 17](17-keep-the-buffer-search-current-occurrence-visible-after-it-is-removed.md) changed the rebuild of the accepted Buffer Search occurrence to `sameSearchIndex`.
A rebuild that removes the current occurrence now clears `buffer_search.active`.

The Buffer Search input preview keeps the nearest rule.
`acceptViewBuild` maps `input.active` with `nearestProjectedSearchIndex`, and the control path `prepareBufferControlForFile` maps it with `nearestSearchIndex`.
While the user types, each scan moves the cursor to `input.active`, and Enter accepts it as `buffer_search.active`.
So `input.active` is also the match under the cursor, like `buffer_search.active`.

A throwaway test shows that a rebuild that removes the preview occurrence moves `input.active` to another match, and the cursor is not on that match.
Enter then jumps to that match.

The fix gives the input preview the rule of ticket 17: a rebuild that removes the preview occurrence clears `input.active`.

## Evidence

All paths are in `src/tui/presentation.zig`. The evidence is from commit `cf2d34c`.

### Reproduction

A throwaway test in a detached worktree drove `Presentation` with this state:

- `testWideSession`, with the geometry 100 × 60.
- Draft 1 on `wide.zig` line 1 with the body `zz one`, and Draft 2 on `wide.zig` line 3 with the body `zz two`. Both Drafts are visible.

Steps:

1. Move the cursor to the header of Draft 2 with `cursorToDraftCard`.
2. Open the Buffer Search input and type `zz`. Complete the scan.
3. With the input open, dispatch `.action = .delete_review_item` and confirm.
4. Run the queued builds.

| Step | Occurrences | `input.active` | Status | Cursor row | Row of the preview occurrence |
| --- | --- | --- | --- | --- | --- |
| After the scan | 2 | 1 (Draft 2) | `2/2` | 13 | 13 |
| After the deletion | 1 | 0 (Draft 1) | `1/1` | 12 | 8 |
| After Enter | 1 | `active` 0 | `1/1` | 8 | 8 |

After the deletion, the status says that match 1 of 1 is current, and the DiffPane highlights the match in Draft 1 as current.
The cursor is on row 12, not on that match. `action_error` is null, so no message appears.
Enter then moves the cursor to row 8, a match that the scan never previewed.
Escape after the deletion closes the input and restores the cursor to row 12.

### Reachability

The real user cannot reach this state today.
While the input is open, `applyKey` sends every key to the input, and `applyMouse` drops every mouse event.
The delete confirmation, the Composer, and the reanchor mode also capture the keys until their Draft mutation ends, so a Draft mutation cannot start or finish behind an open input.
The test reaches the state through a direct `.action` dispatch.
The repo test "M21 kernel Draft mutations rebuild accepted and input Buffer Search on the worker" uses the same dispatch with the input open, so the repo treats the state as legitimate for `Presentation`.

The rebuilds that can run while the input is open are File Enrichment, a cache update, a resize, and the retry of a build that was in flight when the input opened.
These rebuilds add occurrences or keep them.
The ticket 06 and ticket 16 tests show that an `.enrichment` admission keeps the identity of an occurrence.
This survey is inferred from the code. No test proves that no rebuild removes an occurrence.

So the nearest fallback for the input preview is unreachable today, but it gives the ticket 17 state when a future rebuild removes the preview.

## Expected behavior and its precedent

The repo has one rule for the occurrence under the cursor: a non-null index is the match under the cursor, or the index is null.
Ticket 17 applies this rule to `buffer_search.active`.
The input preview follows the same rule while the user types:

- `acceptBufferSearchScanned` moves the cursor to each new `input.active`.
- `retainedEditedSearchIndex` keeps the preview on the same place when the query changes, with no nearest fallback.
- When that function gives null, the preview starts again from the cursor at the input opening: `firstSearchOccurrenceAtOrAfter(navigation_rows, input.origin)`, plus the count.

So a rebuild that removes the preview occurrence clears `input.active`.
The cursor stays where the rebuild put it, and no message appears.
The status shows `-/N` (`formatBufferSearchStatus` in `src/tui/app.zig`).
The next keystroke computes the preview from `input.origin`, as after any query change that loses the preview.
Enter accepts the query with no current occurrence. The cursor stays, and the next `n` searches from the cursor through `searchFromInactiveRow`, as ticket 17 does after a removed occurrence.

The other options have no precedent:

| Option | Why not |
| --- | --- |
| Keep the nearest index (today) | The status and the highlight name a match that the cursor is not on. Enter jumps to a match that the user never previewed. A later keystroke keeps that match through `retainedEditedSearchIndex`. |
| Compute the preview from `input.origin` at the admission | A rebuild would move the cursor without a key press, and a hidden match would need a disclosure build from the admission. No admission does that for the Buffer Search. |

## What to build

1. In `acceptViewBuild`, map `input.active` with a new function that has no nearest fallback:

   ```zig
   /// `sameSearchIndex` through the projected identity order of `next`.
   fn sameProjectedSearchIndex(previous_batch: ?search.Batch, previous_active: ?usize, next: search.Batch, navigation_rows: ?[]SearchNavigationRow) ?usize {
       const previous = previous_batch orelse return null;
       const active = previous_active orelse return null;
       return indexedSearchIdentity(previous.occurrences[active], next, navigation_rows, true);
   }
   ```

   Delete `nearestProjectedSearchIndex`, because it has no other production caller.
   In the test "M21 kernel Buffer Search keeps the previous preview after a refused edit", compare `sameSearchIndex` with `sameProjectedSearchIndex` in place of the two nearest functions.
2. In the control path `prepareBufferControlForFile`, map `input_active` with `sameSearchIndex`, so that the control frame stays an oracle for the worker frame.
3. Rename `retainedEditedSearchIndex` to `sameEditedSearchIndex` and give it a doc comment, for example "The index in `next` of the occurrence at the same place under an edited query, or null when `next` has none."
   The prefix `retained` was the old name of the nearest rule (`retainedSearchIndex` before ticket 17).
   A reader can take it for a nearest fallback, but the function has none.
   The name `same…` puts it in the family of rules without a fallback.
4. Update `tools/check_search_index.py`:
   - Remove the two `NEAREST` entries for the input preview (`prepareBufferControlForFile` and `acceptViewBuild`). The check then fails if either function calls a nearest function again.
   - Remove `nearestProjectedSearchIndex` from `CALL`, and change the fixtures in `tests/check_search_index_test.py` that use it (`INPUT_LINE` and the default `NEAREST` of `check`) to a nearest call that still exists, such as `nearestSearchIndex` in `acceptReviewSearchScanned`.
   - In the module docstring, the Buffer Search input preview uses `sameSearchIndex`, not the nearest rule.
5. Update the doc comment of `nearestSearchIndex` to "A move that the user asked for and a list selection use this rule."
6. Update the `AGENTS.md` row for `tools/check_search_index.py`. Remove the ticket 18 sentence, and say that a rebuild that removes the Buffer Search input preview clears `input.active`. Name the new reproducing test in the enforcement column.

A sketch of steps 1 to 3, step 5, and the `NEAREST` part of step 4 changed 2 production calls, replaced the 7-line `nearestProjectedSearchIndex` with the 6-line `sameProjectedSearchIndex`, and renamed `retainedEditedSearchIndex` at its definition, its production call, and its call in `benchmarkSearchSelection`.
With the sketch, `zig build test --summary all` passed with exit 0: 54/54 steps and 1647/1647 tests, the reproducing test included.

## Acceptance criteria

- [ ] A test through `Presentation`, named for example "M21 kernel Buffer Search input clears its preview when a Draft deletion removes it", reproduces the steps above.
  After the builds, the input batch has 1 occurrence, which equals the Draft 1 occurrence before the deletion (`searchOccurrenceEql`).
  `input.active` is null, the status projection has no active match, the cursor is not on the row of the remaining match, and `action_error` is null.
  After Enter, the input is closed, `buffer_search.active` is null, and the cursor has not moved.
  After `n`, `buffer_search.active` is 0 and the cursor is on the row of the remaining match.
  The test fails at `cf2d34c` on the `input.active == null` check.
- [ ] `acceptViewBuild` and `prepareBufferControlForFile` call no nearest function, and `NEAREST` has no input preview entry.
- [ ] `nearestProjectedSearchIndex` and `retainedEditedSearchIndex` no longer exist. `sameProjectedSearchIndex` and `sameEditedSearchIndex` have doc comments.
- [ ] The ticket 06 test "Buffer Search admits an enrichment rebuild after a current occurrence move and keeps that occurrence", the ticket 16 "M21 kernel Buffer Search retries" tests, and the ticket 17 tests pass.
- [ ] `zig build test` passes. `python3 tools/check_agent_docs.py` passes.

## Overlap with ticket 15

[Ticket 15](15-carry-the-search-destination-in-the-build-kind.md) asks for a type that pairs an occurrence with its batch, or a Kind that carries its destination.
This fix does not need ticket 15.
After this fix, every rebuild of a Buffer Search index uses a `same…` rule, and only a user move and a list selection use the nearest rule.
A type that pairs an index with its batch would make that choice part of the mapping, and the `NEAREST` table could go away.
If ticket 15 lands first, its mapping for the input preview uses the same-occurrence rule.

## Related defect: a rebuild with the input open does not remap the input origin

A second throwaway test found a separate defect that the real user can reach.
`acceptViewBuild` remaps `input.saved_navigation` and `input.origin` only for a `.view` or `.cache_update` build.
An `.enrichment`, `.draft_save`, or `.draft_mutation` build keeps the old visual row numbers.

Steps: in the Whole File scope of the ticket 16 test, put the cursor on the header of File 1 (`a.txt`, row 2), open the input, type `zz`, and deliver a File Enrichment of File 0 that adds rows above.

| Step | Cursor row | `input.origin` | `input.saved_navigation.cursor` | Row of the File 1 header |
| --- | --- | --- | --- | --- |
| Before the input | 2 | | | 2 |
| After the enrichment | 13 (the preview, kept) | 2 | 2 | 7 |
| After Escape | 2, in File 0 | | | 7 |

Escape puts the cursor in File 0, not on the File 1 header where the user opened the input.
A later keystroke that loses the preview also computes it from the stale `input.origin`.
The preview itself stays on the correct match.
This defect is not part of this ticket. [Ticket 19](19-remap-the-buffer-search-input-origin-after-every-rebuild.md) records it.

## Comments

### 2026-11-14, triage

Decision: `ready-for-agent`.

The defect reproduces through `Presentation`, but only through a direct `.action` dispatch.
While the input is open, the keys and the mouse cannot start a rebuild that removes the preview occurrence, so the real user does not see it today.
The rebuilds that can run behind an open input add occurrences or keep them.

The expected behavior follows the rule of ticket 17: an index is the match under the cursor, or it is null.
The preview already follows that rule while the user types, and a lost preview already starts again from `input.origin` on the next keystroke.
So the product call has a precedent, and the ticket needs no answer from a human.
The nearest fallback is not correct even where it is unreachable, because it shows a current match that the cursor is not on.
A `wontfix` would need a `NEAREST` reason that claims that no rebuild removes the preview, and no check keeps that claim true.

`retainedEditedSearchIndex` gets the name `sameEditedSearchIndex`, because `retained` was the old name of the nearest rule and the function has no fallback.

A sketch in a detached worktree made the reproducing test pass, and `zig build test` passed with exit 0.
The sketch left the `CALL` pattern and the check fixtures unchanged, so step 4 has two parts that the sketch did not run.
The second probe found the stale `input.origin` and `input.saved_navigation` after an `.enrichment` admission. The ticket records it for a new ticket.
The probe worktree is deleted. No live run was needed.
