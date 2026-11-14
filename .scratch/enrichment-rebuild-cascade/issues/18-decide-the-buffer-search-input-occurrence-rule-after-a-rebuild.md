# 18: Decide the Buffer Search input occurrence rule after a rebuild

Status: needs-triage
Blocked by: none

## Summary

[Ticket 17](17-keep-the-buffer-search-current-occurrence-visible-after-it-is-removed.md) changed the rebuild of the accepted Buffer Search occurrence to `sameSearchIndex`.
A rebuild that removes the current occurrence now clears `buffer_search.active`.

The Buffer Search input keeps the nearest rule.
`acceptViewBuild` maps `input.active` with `nearestProjectedSearchIndex`, and the control path `prepareBufferControlForFile` maps it with `nearestSearchIndex`.
While the user types, the preview moves the cursor to `input.active`, and `acceptBufferSearch` jumps to it.
So `input.active` also names the match under the cursor, like `buffer_search.active`.

A rebuild while the input is open, for example a File Enrichment or a Draft save that a worker completes, can remove the preview occurrence.
The nearest rule then names another match, maybe a hidden one, and the cursor is not on it.
Enter then jumps to that match.

The ticket 17 runner inferred this from the code. No test reproduced it.

## Question for triage

1. Can a rebuild remove the preview occurrence while the input is open? Write a test through `Presentation` that tries.
2. If it can, should the input use `sameSearchIndex`, or should it keep the nearest rule because the preview follows the query and not the cursor?

`tools/check_search_index.py` lists both input calls in `NEAREST` with a pointer to this ticket.
A change of rule removes those entries.

A type that pairs an occurrence index with its batch would make the rule part of the mapping.
[Ticket 15](15-carry-the-search-destination-in-the-build-kind.md) asks a related question about the build destination.

A third mapping, `retainedEditedSearchIndex`, keeps the input occurrence across a query edit by exact identity.
Its behavior is sound, but its name does not state its rule, and the check does not cover it.
