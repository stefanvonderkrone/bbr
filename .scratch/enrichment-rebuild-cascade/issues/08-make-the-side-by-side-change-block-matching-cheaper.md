# 08: Make the SideBySide change block matching cheaper

Status: needs-triage
Blocked by: none

## Summary

This is win 3 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
A SideBySide Buffer build matches the removed and added Lines of each change block in `emitSideBySideChangeBlock` in `src/tui/buffer.zig`, which the compiler inlines into `Weave.emitSideBySideHunk`.
Its call of `diff.intraline.diff` adds more.
A SideBySide rebuild runs this matching twice, once for the Buffer and once for the search candidates ([ticket 07](07-build-the-search-candidates-without-a-second-buffer.md)).

After ticket 05, a Layout switch to SideBySide costs a median of 372 ms of worker CPU on the ticket 05 workload.
The buffer phase is 161 ms and the candidates phase is 139 ms of it.
The ticket 05 triage profile put about 43 percent of the samples of SideBySide rebuilds in the own time of the change block matching.

## Directions

- The matching result depends only on the Diff, not on the disclosures, the Drafts, or the geometry. The Session can keep it, as it keeps the hunk emphasis in `EmphasisCache`.
- Profile the matching itself before a cache. A cheaper match can be enough.

## Method

Use the workload and the measurement method of ticket 05, with `[DEBUG-t08]` timing marks, and the `side_by_side_matching` case of `zig build bench`.

## Acceptance criteria

- [ ] Each SideBySide Buffer is the same as before: the same rows, pairs, and emphasis.
- [ ] The buffer phase of a Layout switch to SideBySide costs at least 40 percent less worker CPU than the baseline of the same run.
- [ ] `zig build test` passes.
