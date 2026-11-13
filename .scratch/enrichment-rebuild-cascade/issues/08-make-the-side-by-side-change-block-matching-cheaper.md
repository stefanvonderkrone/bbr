# 08: Make the SideBySide change block matching cheaper

Status: ready-for-agent
Blocked by: none

## Summary

This is win 3 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
A SideBySide Buffer build matches the removed and added Lines of each change block in `emitSideBySideChangeBlock` in `src/tui/buffer.zig`, which the compiler inlines into `Weave.emitSideBySideHunk`.
For each pair of a removed and an added Line, it calls `intraline.matchingSimilarity`, which tokenizes both Lines again and fills a byte-weighted common subsequence table (`commonTable`).
Then it calls `intraline.diff` for each matched pair.
A SideBySide rebuild runs this twice, once for the Buffer and once for the search candidates of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

The match uses a similarity only when it is at least `emphasis_threshold` (0.5).
The similarity is `2 * common / (old.len + new.len)`, and the common bytes can never be more than the bytes of the tokens that both Lines contain.
So a cheap upper bound from the token counts of each Line can prove that a pair is below the threshold, and the build can skip the table for that pair with the same result.

## Baseline at `60d7553`

The workload, method, and full table are in the triage comment of ticket 07.

| Rebuild | n | Whole rebuild, median (range) | buffer | candidates |
| --- | --- | --- | --- | --- |
| Layout switch to SideBySide | 12 | 400.9 ms (380.8 to 430.6) | 168.0 ms | 151.9 ms |
| Layout switch to Unified | 12 | 174.6 ms (164.8 to 185.0) | 56.4 ms | 45.5 ms |

The SideBySide buffer and candidates phases cost about 220 ms more than the Unified ones. That difference is the matching, and it is 55 percent of a SideBySide switch.

A `sample` profile of SideBySide resizes put 8,426 samples under `buildFallible`:

- 38.2 percent is the own time of `emitSideBySideHunk` at line 1588. `atos` maps it to `commonTable` and `tokEql` inside `matchingSimilarity`.
- 10.5 percent is `intraline.diff` of the matched pairs.
- About 10 percent is `mmap` and `munmap`. Each change block makes two arenas on the page allocator, and each `intraline.diff` call makes one more, so each one maps and unmaps pages.

## Prototype

The triage tested the bound in a separate worktree at `60d7553`, then removed the worktree.
Before the pair loop, it tokenized each Line once into a sorted list of distinct tokens with their counts and lengths.
For each pair with different text, it added `min(old count, new count) * length` over the shared tokens. When twice that sum over the total length was below `emphasis_threshold`, it set the similarity to 0 and skipped `matchingSimilarity`.
The bound is never lower than the real common byte count, so a skipped pair is always below the threshold, and the match does not change.

With the row array change of the ticket 07 triage in both binaries, the SideBySide switch went from 350.6 ms to 266.0 ms in the same runs. The buffer phase went from 144.5 to 102.9 ms (−29 percent) and the candidates phase from 125.6 to 83.2 ms. The Buffer rows and visual rows were the same.

A profile of the prototype during SideBySide resizes (5,864 samples) shows what remains:

- 29.8 percent is the own time of `emitSideBySideHunk`, the tables of the pairs that the bound does not skip and the bound itself.
- 17 percent is `mmap` and `munmap` from the arenas above.
- 12.9 percent is the prototype bound. It sorts the tokens of each Line with `std.mem.sort`, which is slow.
- 14.8 percent is `intraline.diff`, which includes its own arena.

## What to build

Keep the match result the same, and make it cheaper without state across rebuilds:

1. Tokenize each Line of a change block once, and use the tokens for the bound, the table, and the pair diff.
2. Skip the table of a pair when an upper bound proves that its similarity is below `emphasis_threshold`. Use a bound that is cheap to compute, for example a token count list that the build sorts with a cheap key, or a token hash table per change block.
3. Use one scratch arena per Buffer build for the change block work and for `intraline.diff`, and reset it for each change block, so that no change block and no pair maps pages.

## Rejected directions

- Keep the match result of each change block in the Session, as `EmphasisCache` keeps the hunk emphasis. The result depends only on the Diff, so this would remove the matching from each build after the first. But the build runs on a worker, and the Session is read-only there, so the cache needs a new hand-back from the worker to the Session, or a build at Session load for every user. The stateless steps need neither. If the SideBySide switch is still too slow after this ticket, measure this cache in a new ticket.

## Method

Use the method of ticket 07 with `[DEBUG-08]` marks.
Also extend the `side_by_side_matching_*` cases of `zig build bench`. Their checksum now covers the row kinds and the Line text only. Add the pair of each row and the emphasis segments of each side to the checksum, so that a changed match changes the checksum.
In `synthetic.replacementBlock`, a removed and an added Line with different numbers share `const`, the spaces, `=`, and `;`, so the bound skips them. Keep the case, and add one where most pairs are above the threshold, so that the benchmark shows the cost of the bound when it skips nothing.

## Acceptance criteria

- [ ] A test compares the match of each change block with the match of the code before this change, for change blocks where the bound skips every pair, no pair, and some pairs, for empty Lines, equal Lines, and Lines at the threshold. The pairs, their order, and the emphasis segments are the same.
- [ ] The `zig build bench` checksum of each `side_by_side_matching_*` case covers the pairs and the emphasis, and is the same before and after the change.
- [ ] On the workload, the median of the buffer phase of a Layout switch to SideBySide is at least 40 percent lower than the baseline of the same run.
- [ ] On the workload, the median worker CPU of a Layout switch to SideBySide is at least 25 percent lower than the baseline of the same run.
- [ ] The phases of a Unified rebuild do not change by more than the run-to-run spread.
- [ ] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [ ] No `[DEBUG-08]` or `[DEBUG-t07]` line stays in the repository.
- [ ] `zig build test` passes.

## Comments

### 2026-11-13 triage

The runner asked for a triage of tickets 07, 08, and 09 together, and set this ticket to `ready-for-agent`.
The measurement, the load, and the full phase table are in the triage comment of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

The first version of this ticket asked for a cache in the Session or a cheaper match. The profile shows that the cost is the table of pairs that the threshold rejects, and the page mapping of the arenas. Both go away without state, so this version chooses the stateless steps.
The prototype measured only the bound. Steps 1 and 3 have no prototype. The profile of the prototype supports them: `mmap` and `munmap` are 17 percent and the slow bound is 12.9 percent of its samples.

**Dependencies.** None. Ticket 07 reuses the corpus only when the Layout does not change, so a SideBySide switch still runs the matching twice, and this ticket saves it in both builds. The row array change of the ticket 07 triage lowers the buffer phase of both Layouts. Measure against a baseline of the same run.
