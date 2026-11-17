# 07: Find the other rebuild lists that grow from empty

Status: needs-triage
Blocked by: none

## Summary

[Ticket 25](../../enrichment-rebuild-cascade/issues/25-measure-the-page-faults-of-the-phases-after-the-visual-rows.md) sized the visual rows, the `NavigationIndex` maps, and `source_rows` before their loops.
Its research found more lists and maps in the rebuild path that grow from empty although a bound is known before the loop.
Nobody measured them. Each growth in an arena leaves the replaced memory behind, and each growth outside an arena copies.

| Function | File | What grows | Known bound |
| --- | --- | --- | --- |
| `buildSearchCandidates` | `src/tui/buffer.zig` | the candidate list | at most the semantic Buffer rows plus the body pieces |
| `buildSearchCandidates` | `src/tui/buffer.zig` | the disclosure list | 1 + 2 × Files + threads + Replies + Drafts |
| `SearchProjection.createWithAllocator` | `src/tui/presentation.zig` | `body_rows`, `disclosure_rows` | the ReviewCard and disclosure counts |
| `SearchProjection.indexDisclosures` | `src/tui/presentation.zig` | its maps | 2 × Files, fold lines, Comments, Drafts |
| `buildWithComments` | `src/tui/buffer.zig` | `file_rows`, `tree_starts` | Files, threads |

[Ticket 12](04-grow-the-search-projection-ranges-without-copies.md) already owns the projected search ranges.

## What the triage decides

- Measure each site on the workload and the method of ticket 25: allocations, failed remaps, faults, and thread CPU per phase.
- Keep only the sites whose growth costs more than the run-to-run range of a rebuild. Most of them are small.
- For each kept site, extend the growth tests of ticket 25 ("visual rows build in one allocation without a growth copy in both Layouts" and "a NavigationIndex whose keys each have one span grows nothing" in `src/tui/frame.zig`), so that a later change cannot bring the growth back.

## Comments

### 2026-11-16 moved for a later PullRequest

The operator moved this ticket out of the enrichment rebuild cascade, where it was ticket 27, so that a later PullRequest owns it.
Ticket numbers in the text above are the numbers of the enrichment rebuild cascade. [The map](../map.md) lists the new numbers.
Take a new baseline at the head of the branch that starts this work.

