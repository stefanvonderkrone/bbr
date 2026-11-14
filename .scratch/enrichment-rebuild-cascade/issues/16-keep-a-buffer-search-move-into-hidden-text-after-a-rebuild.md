# 16: Keep a Buffer Search move into hidden text after a rebuild

Status: needs-triage
Blocked by: none

## Summary

A Buffer Search `n` or `N` to a match that is hidden, for example in a collapsed fold or a collapsed disclosure, queues an `.accepted` or `.restore` build.
When another Buffer rebuild is admitted before that build ends, the `.accepted` build can be dropped with no retry and no message.
The user then presses `n`, and nothing happens.

This gap is older than [ticket 06](06-keep-a-buffer-rebuild-after-a-buffer-search-active-move.md).
The ticket 06 code review found it, and the ticket 06 completion records it.
Ticket 06 admits more rebuilds while the user presses `n`, so the gap can now occur more often.
Nobody has reproduced it. The evidence is a read of the code at commit `d5d9dbe`.

## Evidence

All paths are in `src/tui/presentation.zig`.

1. `traverseBufferSearchBy` jumps directly to a visible match.
   For a hidden match, it calls `queueAcceptedDisclosure` with the kind `.accepted`, or `.restore` when no disclosure must open.
   It does not change `buffer_search.active`. The build sets it when the Presentation admits the build.
2. The build copies the accepted batch into `accepted_snapshot` when it starts.
3. `acceptViewBuild` admits a rebuild, for example a File Enrichment result.
   It replaces `published.buffer_search.accepted_batch` with the rebuilt batch of that rebuild.
4. `acceptAcceptedDisclosure` then compares the snapshot pointer with the current accepted batch:

   ```zig
   if (current == null or snapshot.occurrences.ptr != current.?.occurrences.ptr) return;
   ```

   On a mismatch, it returns. It does not call `retryAcceptedDisclosure`, and it sets no `action_error`.
   The other stale checks in the same function call `retryAcceptedDisclosure`.

The live runs of ticket 06 ended on the expected match index in every run.
But they did not check that the DiffPane showed the match, and they did not aim `n` at hidden matches.

## Next step

Triage the ticket:

1. Write a test through `Presentation` that does these steps:
   - Press `n` to a hidden match.
   - Admit a File Enrichment rebuild before the `.accepted` build ends.
   - Deliver the `.accepted` build.

   Check whether the match opens and the cursor reaches it.
2. When the test confirms the drop, decide the fix.
   One possible fix: map the target occurrence into the current accepted batch with `retainedSearchIndex` and admit or retry the build, as other stale checks do.
   Another possible fix: retry the build with the target mapped into the new batch.
3. Check whether the live workload can show the drop.
   For example, use `n` at 10 presses per second on a query whose matches are mostly in collapsed folds while File Enrichment runs.
   Count the dropped `.accepted` builds.
4. Set the status and the acceptance criteria.

## Comments
