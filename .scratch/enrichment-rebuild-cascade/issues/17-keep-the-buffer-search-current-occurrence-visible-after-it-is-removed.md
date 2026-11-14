# 17: Keep the Buffer Search current occurrence visible after it is removed

Status: ready-for-agent
Blocked by: none

## Summary

Two cases leave the Buffer Search in a state that no user action can produce.
Both cases came up during [ticket 16](16-keep-a-buffer-search-move-into-hidden-text-after-a-rebuild.md).

1. A Buffer rebuild removes the current occurrence, for example a Draft deletion.
   The current occurrence moves to another match that can be hidden.
   The status shows that match as current, but the cursor is not on it and the DiffPane does not show it.
2. A retried traversal move lands in a rebuilt batch that is empty.
   The retry opens the disclosures of the old target, which no longer matches.

The fix makes a rebuild clear the current occurrence when the occurrence is gone, and makes the retry into an empty batch behave like `n` on an empty batch.

## Evidence

All paths are in `src/tui/presentation.zig`. The evidence is from commit `7e1930b`.
Two throwaway tests drove `Presentation` in a detached worktree.
Both tests use two Drafts on `a.txt` line 1, each with the body `one`, `two`, `three`, `four`, `five`, and `zz` in separate paragraphs, and `comments_collapsed_rows = 2`.
So `zz` is hidden while a Draft is collapsed.
Each test accepts the Buffer Search `zz`, which opens the first Draft.

### Case 1: a rebuild removes the current occurrence

Steps after the accepted search:

1. Press `n`. The move opens the second Draft and closes the first one.
2. Press `D` on the second Draft and confirm.
3. Run the queued builds.

No race is necessary. The ticket first described a Draft deletion retried behind an `n`, but a direct deletion of the current Draft shows the same result.

| Step | Occurrences | `buffer_search.active` | Status | Cursor row | Row of the current occurrence |
| --- | --- | --- | --- | --- | --- |
| Accepted | 2 | 0 | `1/2` | 19 | 19 |
| After `n` | 2 | 1 | `2/2` | 24 | 24 |
| After the deletion | 1 | 0 | `1/1` | 8 | none (hidden) |

After the deletion, the status says that match 1 of 1 is current.
That match is in the first Draft, which is collapsed, so the DiffPane shows no current match and the cursor is on row 8.
`action_error` is null, so no message appears.

The cause is the admission in `acceptViewBuild`:

```zig
const active = if (job.rebuilt_batch) |rebuilt| retainedSearchIndex(published.buffer_search.accepted_batch, published.buffer_search.active, rebuilt) else published.buffer_search.active;
```

When the occurrence is gone, `retainedSearchIndex` gives the nearest index that is in bounds.
That fallback is correct for a move that the user asked for, such as the retry of ticket 16.
It is not correct for a rebuild, because a rebuild does not move the cursor to the new index.
Every `.view`, `.enrichment`, `.cache_update`, `.draft_save`, `.draft_mutation`, `.card_destination`, and `.review_destination` admission goes through this line.

### Case 2: a retried traversal move into an empty batch

Steps after the accepted search:

1. Press `gg` (`to_top`). The cursor leaves the match, `clearBufferSearchActive` restores the disclosures, and no Draft is open.
2. Press the isolate key on File `0.txt`, which has no match. A `.view` build waits in the queue.
3. Press `n`. The next match is in the collapsed first Draft, so an `.accepted` build waits behind the `.view` build.
4. Run the queued builds.

The `.view` build is admitted first, and the batch has 0 occurrences.
The `.accepted` build is then retried.
`retryAcceptedDisclosure` maps its destination to null and queues the old `target` with a null destination.

| After the builds | Value |
| --- | --- |
| Occurrences | 0 |
| `buffer_search.active` | null |
| `action_error` | null |
| `expanded_disclosures` | 1 key (it was 0) |
| `buffer_search.saved_disclosures` | set (it was null) |

The earlier triage said that no message appears.
That is not correct for the status: `formatBufferSearchStatus` in `src/tui/app.zig` shows `0/0 · No matches` whenever the query is not empty and the total is 0.
The real defect is the disclosure.
The retry opened the first Draft, which no longer has a match, and saved a baseline for a move that did not happen.
When the user leaves the isolation, that Draft is open. This last effect is inferred from the kept key. The test did not leave the isolation.

## Expected behavior and its precedent

The repo has one rule for the current occurrence: a non-null `buffer_search.active` is the match under the cursor.

- Each motion in the DiffPane that moves the cursor calls `clearBufferSearchActive` (the motion check in `applyAction`, and the `.diff_row` mouse handler).
- `landOnCard` clears `active` when a card destination moves the cursor.
- With a null `active`, `n` and `N` search from the cursor through `searchFromInactiveRow`.
- The status shows `-/N` for a null `active` (`formatBufferSearchStatus`).

So a rebuild that removes the current occurrence clears `active`, and the cursor stays where the rebuild put it.
The next `n` searches from the cursor, as after any motion.
No message appears, as after any motion.

The other options have no precedent:

| Option | Why not |
| --- | --- |
| Keep the nearest index (today) | The status names a match that the cursor is not on. The next `n` starts from a match that the user never reached. |
| Move to the nearest visible match | A rebuild would move the cursor without a key press. No admission does that for the Buffer Search. |
| Open the hidden match | A rebuild would open a disclosure and move the cursor without a key press. A Draft deletion would show a different Draft. |

The clear keeps `buffer_search.saved_disclosures`.
The next `n` or `N` then builds its target on the saved baseline, and `Escape` restores the baseline, as before the deletion.
The admission must not call `clearBufferSearchActive`, because that queues a `.restore` build, and `queueAcceptedDisclosure` removes a queued traversal build.

For case 2, a retried traversal move behaves like `traverseBufferSearchBy` on an empty batch.
It sets `action_error` to `buffer_search_no_matches`, opens nothing, and queues nothing.

## What to build

1. Add a function that finds the same occurrence and has no nearest fallback:

   ```zig
   /// The index of the same occurrence in `next`, or null when `next` lost it.
   fn sameSearchIndex(previous_batch: ?search.Batch, previous_active: ?usize, next: search.Batch) ?usize {
       const previous = previous_batch orelse return null;
       const active = previous_active orelse return null;
       for (next.occurrences, 0..) |candidate, index| if (searchOccurrenceEql(previous.occurrences[active], candidate)) return index;
       return null;
   }
   ```

   `acceptViewBuild` uses it in place of `retainedSearchIndex` for `buffer_search.active`.
   `retainedSearchIndex` stays for the retry of ticket 16, the input batch, and Review Search.
   The test-only control path `prepareBufferControlForFile` also maps `accepted_active` with `retainedSearchIndex`. Change it to `sameSearchIndex` too, so that the control frame stays an oracle for the worker frame.

2. In `retryAcceptedDisclosure`, a traversal move always ends in the traversal branch:

   ```zig
   if ((job.kind == .accepted or job.kind == .restore) and job.restore_navigation == null and job.destination_active != null) {
       if (destination) |index| {
           self.openBufferSearchOccurrence(published, index, job.result_error);
       } else self.action_error = .buffer_search_no_matches;
       return;
   }
   ```

   The condition `job.destination_active != null` is necessary.
   The `.restore` of `clearBufferSearchActive` also has a null `restore_navigation`, but its destination is null, and it must still restore the disclosures.
   A sketch without that condition failed the ticket 16 test "M21 kernel Buffer Search retries null destinations after enrichment without selecting a match".

A sketch of both steps, with the control path change, added 12 production lines and changed 5.
With the sketch, `zig build test --summary all` passed: 52/52 steps and 1646/1646 tests, including the two reproducing tests and the four ticket 16 tests.

## Acceptance criteria

- [ ] A test through `Presentation` reproduces case 1: accept `zz`, press `n` to the second Draft, delete that Draft with `D` and confirm, and run the builds.
  After the builds, the batch has 1 occurrence, `buffer_search.active` is null, the status projection has no active match, the cursor keeps its row, and `action_error` is null.
  Then `n` makes the remaining occurrence current, and the cursor is on its visual row.
  The test fails at `7e1930b`, where `active` is 0 and the occurrence has no visual row.
- [ ] A test through `Presentation` reproduces case 2: accept `zz`, press `gg`, isolate File `0.txt`, press `n`, and run the builds.
  After the builds, the batch is empty, `action_error` is `buffer_search_no_matches`, `expanded_disclosures` has the keys from before the `n`, and `buffer_search.saved_disclosures` is null.
  The test fails at `7e1930b`, where `action_error` is null and one Draft disclosure is open.
- [ ] A rebuild that keeps the current occurrence still keeps it.
  The ticket 06 test "Buffer Search admits an enrichment rebuild after a current occurrence move and keeps that occurrence" passes.
- [ ] The four "M21 kernel Buffer Search retries" tests of ticket 16 pass.
- [ ] `zig build test` passes.

## Overlap with ticket 15

[Ticket 15](15-carry-the-search-destination-in-the-build-kind.md) asks whether `DisclosureBuild.Kind` should carry its destination.
This fix does not need ticket 15.
Step 2 adds `job.destination_active != null` to the test that tells a traversal move from other kinds, so that test now reads three fields.
A Kind with a traversal arm that carries its occurrence would replace all three.
If ticket 15 lands first, step 2 matches that arm instead.

## Comments

### 2026-11-14, triage

Decision: `ready-for-agent`.

Both cases are real defects.
Case 1 needs no race. A direct deletion of the current Draft leaves the status on a hidden match while the cursor is elsewhere.
Case 2 shows `0/0 · No matches` already, because the status reads the empty total. The defect is the disclosure that the retry opens for a match that no longer exists.

The expected behavior follows the rule that every cursor motion already applies: the current occurrence is the match under the cursor, or none.
So the product call has a precedent, and the ticket needs no answer from a human.

A sketch in a detached worktree fixed both throwaway tests.
`zig build test` passed with the sketch, ticket 16's tests included.
The first sketch of step 2 broke the ticket 16 null-destination test, and the ticket records the condition that fixes it.

The runner rewrote the ticket around the observed results and the fix.
The probe worktree is deleted. No live run was needed.
