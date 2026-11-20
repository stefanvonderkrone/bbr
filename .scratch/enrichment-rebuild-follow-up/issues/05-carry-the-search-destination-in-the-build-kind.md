# 05: Carry the search destination in the build kind

Status: needs-triage
Blocked by: none

## Summary

A cheap search selection change started expensive work three times on this branch.
[Ticket 03](../../enrichment-rebuild-cascade/issues/03-move-the-review-search-selection-without-a-full-projection.md) stopped a full projection of every occurrence for each Review Search selection move.
[Ticket 04](../../enrichment-rebuild-cascade/issues/04-keep-a-buffer-rebuild-after-a-review-search-selection-move.md) removed the Review Search selection from `DisclosureBuild`.
[Ticket 06](../../enrichment-rebuild-cascade/issues/06-keep-a-buffer-rebuild-after-a-buffer-search-active-move.md) removed the Buffer Search current occurrence from `DisclosureBuild`.

After ticket 06, a build keeps an occurrence only in two optional fields.
`destination_occurrence` serves a `.review_destination` build.
`destination_active` serves a build whose `Kind.opensOccurrence` holds.
Both fields exist on every build kind.
So an `.enrichment` or `.view` build can still set or read one, and the compiler accepts it.
Only the tests that [the TUI state rules](../../../docs/rules/tui-state.md#search-selection-in-a-buffer-rebuild) name fail.

## Question for triage

Should `DisclosureBuild.Kind` become a tagged union whose destination kinds carry their occurrence, for example `.accepted: ?usize` and `.review_destination: usize`?
Then no other kind can hold an occurrence, and the two optional fields go away.

The change touches about 320 `kind` uses in `src/tui/presentation.zig`.
Most are `job.kind == .x` comparisons, which Zig accepts for a tagged union.
Tests that compare `DisclosureBuild.Kind.x` with `job.kind` through `expectEqual` must change to `std.meta.activeTag`.

A shared owner for the active occurrence of both searches is a second option.
The DiffPane takes the active Buffer Search ranges from `buffer_search.active` (`src/tui/render.zig`), but the active Review Search ranges from the `active` flag that `markActiveSearchRanges` sets.
One rule for both would remove the flag marking of Review Search ranges.

## Comments

### 2026-11-14, from ticket 16

[Ticket 16](../../enrichment-rebuild-cascade/issues/16-keep-a-buffer-search-move-into-hidden-text-after-a-rebuild.md) found that `retryAcceptedDisclosure` reused `destination_active` against a newer accepted batch.
The fix maps it with `retainedSearchIndex` and tells a traversal move from other kinds by `job.restore_navigation == null`.
A Kind that carries the destination as the occurrence identity, or as an index together with its batch, would make an unmapped read of another batch impossible.
It would also replace the `restore_navigation == null` test.
A survey of the branch found six places that map a stored occurrence index into a new batch correctly, and only this retry did not.
So the mistake does not count as a repeated class yet, and ticket 16 adds no check for it.

### 2026-11-16 moved for a later PullRequest

The operator moved this ticket out of the enrichment rebuild cascade, where it was ticket 15, so that a later PullRequest owns it.
Ticket numbers in the text above are the numbers of the enrichment rebuild cascade. [The map](../map.md) lists the new numbers.
Take a new baseline at the head of the branch that starts this work.

