# 17: Keep the Buffer Search current occurrence visible after it is removed

Status: needs-triage
Blocked by: none

## Summary

Two cases leave the Buffer Search on an occurrence that the user cannot see, or on no occurrence, with no message.
Both cases came up during [ticket 16](16-keep-a-buffer-search-move-into-hidden-text-after-a-rebuild.md).
Ticket 16 does not fix them, because each one is outside the retry of a traversal move.

## Evidence

All paths are in `src/tui/presentation.zig`. The evidence is from commit `132d933`.

### A rebuild removes the current occurrence

`acceptViewBuild` maps the published current occurrence into the rebuilt batch with `retainedSearchIndex`.
When the occurrence is gone, `retainedSearchIndex` gives the nearest index that is in bounds.
Nothing opens the disclosures of that occurrence, and nothing moves the cursor to it.

A throwaway test in ticket 16 showed this:

1. `testDisclosureSession` with `comments_collapsed_rows = 2` and two Drafts on `a.txt`, at lines 1 and 12.
   Each Draft body ends with `zz` after the collapsed rows.
2. Accept the Buffer Search `zz`. Occurrence 0 is the first Draft, and its disclosure is open.
3. Queue the File Enrichment of File 0, then the deletion of the second Draft, then press `n` toward the second Draft.
4. Run the queued builds in order.

The deletion build has a stale `request_id` after the `n`, so the Presentation retries it behind the move.
The move is admitted first and opens the second Draft.
Then the deletion is admitted.
The batch has 1 occurrence, `buffer_search.active` is 0, `occurrenceVisualRow` of that occurrence is null, and the cursor is on row 17.
The status shows the first Draft as the current match, but its text is hidden and the cursor is not on it.

### A retried traversal move into an empty batch

When a rebuild admitted before a retried traversal move leaves the accepted batch empty, `retryAcceptedDisclosure` maps the destination to null.
The retry then queues the old disclosure target with a null destination.
The admission opens the disclosures of a match that no longer exists, sets `buffer_search.active` to null, and shows no message.
`traverseBufferSearchBy` shows `buffer_search_no_matches` for an empty batch.
This is inferred from the code. No test made the batch empty.
An isolation of a File without matches before the `n` can probably reach it.

## Question for triage

Should a rebuild that removes the current occurrence open the disclosures of the mapped occurrence and move the cursor to it, as a traversal move does?
Should a retried traversal move into an empty batch show `buffer_search_no_matches` and keep the disclosures?

## Comments
