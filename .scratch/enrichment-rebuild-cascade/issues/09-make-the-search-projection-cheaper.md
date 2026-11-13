# 09: Make SearchProjection.create cheaper

Status: ready-for-agent
Blocked by: none

## Summary

This is win 4 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
`SearchProjection.create` in `src/tui/presentation.zig` runs on every rebuild.
It builds hash maps over all visual rows: the `NavigationIndex` (`owners` and `spans`, in `src/tui/frame.zig`), the `SourceRowKey` rows (`source_rows`), the body rows, and the disclosure rows.
Every map value of `spans` and `source_rows` is its own `ArrayList`, and most of them hold one row.

The `owners` map gets an entry for each visual row, also for each `.line` owner.
No code reads a `.line` entry: `NavigationIndex.find` reads `owners` only when the owner is not `.line`, and every other `owners.get` caller asks for a ReviewCard header, a Draft header, or a disclosure.
So most of the `owners` work has no reader.

## Baseline at `60d7553`

The workload, method, and full table are in the triage comment of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

| Rebuild | n | Whole rebuild, median (range) | projection |
| --- | --- | --- | --- |
| Disclosure toggle, Unified | 24 | 119.9 ms (104.1 to 140.1) | 53.1 ms |
| Resize, Unified | 24 | 172.2 ms (152.5 to 236.7) | 53.4 ms |
| Layout switch to SideBySide | 12 | 400.9 ms (380.8 to 430.6) | 55.8 ms |

The projection is 44 percent of a disclosure toggle and 31 percent of a Unified resize.

A `sample` profile of Unified resizes put 1,357 samples in `SearchProjection.create`:

| Part | Share |
| --- | --- |
| `addSourceRow` (`source_rows`, with its map growth) | 27.6 % |
| `owners.getOrPutContext` | 25.4 % |
| `NavigationIndex.add` (`spans`) | 17.5 % |
| `owners` map growth | 14.8 % |
| `source_rows` map growth | 5.8 % |
| Own time of the row loop | 21 % |

The shares overlap, because a part includes the hash and allocation calls under it. Map growth is about 20 percent, not the 5 percent that the ticket 05 profile showed.

## Prototype

The triage tested two steps in separate worktrees at `60d7553`, then removed the worktrees. Both binaries also held the row array change and the bound of ticket 08, which do not touch this phase.

1. Reserve the capacity of `spans`, `owners`, and `source_rows` from the visual row count before the loop.
2. Do not put `.line` owners in `owners`.

Projection phase medians, in ms:

| Rebuild | Baseline (first runs) | Step 1 (first runs) | Step 1 (second runs) | Steps 1 and 2 (second runs) |
| --- | --- | --- | --- | --- |
| Disclosure toggle | 53.1 | 48.8 | 46.3 | 40.9 |
| Resize, Unified | 53.4 | 46.1 | 43.6 | 38.9 |
| Switch to Unified | 50.7 | 46.5 | 43.2 | 38.5 |
| Switch to SideBySide | 55.8 | 57.3 | 54.9 | 48.0 |

The first runs alternated baseline and step 1, three times each. The second runs alternated step 1 and steps 1 and 2, three times each. Each median has 12 or 24 rebuilds.
Step 2 saves 5 to 7 ms in each rebuild kind. Step 1 saves 4 to 7 ms in Unified and nothing in SideBySide.
Together they make the projection about 23 percent cheaper in Unified. The remaining cost is mostly `addSourceRow` and `NavigationIndex.add`, which make one `ArrayList` for each key.

## What to build

1. Do not insert `.line` owners into `NavigationIndex.owners`.
2. Reserve the map capacity before the loop.
3. Store the rows of a `source_rows` key and the spans of a `spans` key without one `ArrayList` for each key. For example, keep the first row in the map value and use a list only for a second row, or put all entries in one flat array and keep a slice for each key. `occurrenceRows` and `NavigationIndex.find` must still get the rows and spans in the same order.

## Rejected directions

- Build the indexes on the first search. The projection is shared with the Presentation thread, so a lazy index needs a lock, and it moves the cost to the first keystroke of a Buffer Search. Commit `72a7f35` moved this work to the worker to remove that stall.
- Replace the `NavigationIndex` with a walk of the visual rows. Commit `26ad200` measured 1.28 ms at p95 for the linear walk and 19 µs for the index, and the Presentation thread calls `find` on a jump.

## Method

Use the method of ticket 07 with `[DEBUG-09]` marks.

## Acceptance criteria

- [ ] A test builds the projection of Unified and SideBySide Buffers with wrapped Lines, context Lines on both sides, ReviewCards, Drafts, folds, and disclosures. For every source key, body owner, and visual row, `occurrenceRows`, `NavigationIndex.find`, the `owners` lookups of ReviewCard headers, Draft headers, and disclosures, `requiredDisclosures`, and `disclosure_rows` give the same result as the code before this change.
- [ ] Buffer Search results and the cursor restoration after a resize are the same as before the change.
- [ ] On the workload, the median of the projection phase of a Unified disclosure toggle is at least 30 percent lower than the baseline of the same run.
- [ ] The projection phase of a Layout switch to SideBySide is at least 15 percent lower than the baseline of the same run.
- [ ] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [ ] No `[DEBUG-09]` or `[DEBUG-t07]` line stays in the repository.
- [ ] `zig build test` passes.

## Comments

### 2026-11-13 triage

The runner asked for a triage of tickets 07, 08, and 09 together, and set this ticket to `ready-for-agent`.
The measurement, the load, and the full phase table are in the triage comment of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

The first version of this ticket said that map growth was a small part and asked for a profile first. The profile at `60d7553` shows that growth is about 20 percent of the phase, and that the `.line` entries of `owners` have no reader. Steps 1 and 2 have prototype numbers. Step 3 has none, and the 30 percent target needs it.
If step 3 does not reach the target, record the numbers and set the ticket to `needs-info`.

**Dependencies.** None. Tickets 07 and 08 do not change this phase. The projection runs once on each rebuild, also when ticket 07 reuses the corpus.
