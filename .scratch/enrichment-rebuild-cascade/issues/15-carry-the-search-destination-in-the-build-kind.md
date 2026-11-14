# 15: Carry the search destination in the build kind

Status: needs-triage
Blocked by: none

## Summary

A cheap search selection change started expensive work three times on this branch.
[Ticket 03](03-move-the-review-search-selection-without-a-full-projection.md) stopped a full projection of every occurrence for each Review Search selection move.
[Ticket 04](04-keep-a-buffer-rebuild-after-a-review-search-selection-move.md) removed the Review Search selection from `DisclosureBuild`.
[Ticket 06](06-keep-a-buffer-rebuild-after-a-buffer-search-active-move.md) removed the Buffer Search current occurrence from `DisclosureBuild`.

After ticket 06, a build keeps an occurrence only in two optional fields.
`destination_occurrence` serves a `.review_destination` build.
`destination_active` serves a build whose `Kind.opensOccurrence` holds.
Both fields exist on every build kind.
So an `.enrichment` or `.view` build can still set or read one, and the compiler accepts it.
Only the tests that `AGENTS.md` names fail.

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
