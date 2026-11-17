# 09: Make SearchProjection.create cheaper

Status: resolved
Blocked by: 25

## Summary

This is win 4 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
`SearchProjection.create` in `src/tui/presentation.zig` runs on every rebuild.
It builds hash maps over all visual rows: the `NavigationIndex` (`owners` and `spans`, in `src/tui/frame.zig`), the `SourceRowKey` rows (`source_rows`), the body rows, and the disclosure rows.
Every map value of `spans` and `source_rows` is its own `ArrayList`, and most of them hold one row.

The `owners` map gets an entry for each visual row, also for each `.line` owner.
No code reads a `.line` entry: `NavigationIndex.find` reads `owners` only when the owner is not `.line`, and every other `owners.get` caller asks for a ReviewCard header, a Draft header, or a disclosure.
So most of the `owners` work has no reader.

## Baseline at `6f9f09f`

Ticket 25 already reserves the map capacity and gives each new key list room for one entry, so step 2 of [What to build](#what-to-build) is done.
This baseline replaces the baseline at `60d7553` below.

Method of ticket 25, ReleaseFast, `[DEBUG-09]` marks in a detached worktree. 3 runs, each with 8 resizes, 8 disclosure toggles, and 8 Layout switches. Thread CPU of the worker per rebuild, median [range], in ms. The 1-minute load average was 3.1 to 4.7 on the Apple M5 Pro with 18 cores.

| Rebuild | n | Whole rebuild | Projection | Projection faults | Allocations in the projection |
| --- | --- | --- | --- | --- | --- |
| Resize, Unified | 24 | 91.7 [69.8, 101.5] | 40.7 [36.9, 48.0] | 6,051 | 382,339 |
| Disclosure toggle, Unified | 24 | 88.1 [65.3, 96.4] | 38.8 [36.4, 43.3] | 6,001 | 382,265 |
| Switch to Unified | 12 | 122.3 [106.0, 127.3] | 37.4 [36.2, 41.1] | 6,000 | 382,265 |
| Switch to SideBySide | 12 | 135.2 [120.1, 237.8] | 50.1 [49.0, 61.4] | 9,768 | 394,249 |

The allocations are the calls through the projection arena of `SearchProjection.createWithAllocator` before `indexDisclosures`. A SideBySide projection also has 12,362 failed remaps, which are growth copies of key lists.
Process CPU (`ps -o time=`) for 8 resizes was 0.79, 0.80, and 0.82 s. For 8 toggles it was 0.79, 0.81, and 0.82 s, and for 8 Layout switches 1.16, 1.17, and 1.23 s. The RSS was 410 MB after the resizes and 512 MB after the Layout switches.

## Old baseline at `60d7553`

This baseline is obsolete. Ticket 25 changed the projection after it.


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

- [x] A test builds the projection of Unified and SideBySide Buffers with wrapped Lines, context Lines on both sides, ReviewCards, Drafts, folds, and disclosures. For every source key, body owner, and visual row, `occurrenceRows`, `NavigationIndex.find`, the `owners` lookups of ReviewCard headers, Draft headers, and disclosures, `requiredDisclosures`, and `disclosure_rows` give the same result as the code before this change.
- [x] Buffer Search results and the cursor restoration after a resize are the same as before the change.
- [x] On the workload, the median of the projection phase of a Unified disclosure toggle and of a Unified resize is at least 20 percent lower than the baseline at `6f9f09f` of the same run.
- [x] The median of the projection phase of a Layout switch to SideBySide is at least 20 percent lower than the baseline at `6f9f09f` of the same run.
- [ ] The process CPU of 8 resizes is lower than the baseline by more than the range of the runs. Waived on 2026-11-16: the median fell from 0.79 to 0.72 s, inside the run-to-run range. See the operator decision of that date.
- [x] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [x] No `[DEBUG-09]` or `[DEBUG-t07]` line stays in the repository.
- [x] `zig build test` passes.

## Comments

### 2026-11-13 triage

The runner asked for a triage of tickets 07, 08, and 09 together, and set this ticket to `ready-for-agent`.
The measurement, the load, and the full phase table are in the triage comment of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

The first version of this ticket said that map growth was a small part and asked for a profile first. The profile at `60d7553` shows that growth is about 20 percent of the phase, and that the `.line` entries of `owners` have no reader. Steps 1 and 2 have prototype numbers. Step 3 has none, and the 30 percent target needs it.
If step 3 does not reach the target, record the numbers and set the ticket to `needs-info`.

**Dependencies.** None. Tickets 07 and 08 do not change this phase. The projection runs once on each rebuild, also when ticket 07 reuses the corpus.

### 2026-11-15 blocked by ticket 25

[Ticket 25](25-measure-the-page-faults-of-the-phases-after-the-visual-rows.md) sizes the `SearchProjection` indexes and gives each new key list room for one entry.
That change covers step 1 of this ticket and part of step 3.
After ticket 25 lands, this ticket takes a new baseline and keeps the flat entry layout, which removes the growth copies of SideBySide key lists that ticket 25 leaves.

### 2026-11-16 new baseline and targets

Ticket 25 is resolved. It made the projection about 25 percent cheaper in Unified with step 2 of What to build and part of step 3. The old targets compared against `60d7553` and counted that saving, so they no longer apply.
The user approved this plan: take a fresh baseline at `6f9f09f`, do step 1 (no `.line` owners) and step 3 (key lists without one list per key) in separate commits, and measure each step against the fresh baseline in the same alternating run.
The new targets are in the acceptance criteria: the projection phase at least 20 percent lower for a Unified toggle, a Unified resize, and a switch to SideBySide, and lower process CPU for 8 resizes by more than the run-to-run range.
If step 3 misses its target, record the numbers and set this ticket to `needs-info`. Ticket 12 (projected search ranges) stays out of scope.

### 2026-11-16 result: needs-info

Both steps are done and committed. The projection targets are met. The process CPU target of 8 resizes is not proven, so this ticket goes to `needs-info` as the plan says.

**Change.**

- `30afd1d` pins the projection lookups in the forms that their readers use. The test "search projection lookups match the 6f9f09f baseline in both Layouts" hashes `occurrenceRows` for every source key and body owner, `NavigationIndex.find` for every visual row at its start and at an offset inside it, the `owners` lookup of every row whose owner is not a Line, the ReviewCard header, Draft header, and resolved Thread disclosure lookups, `requiredDisclosures`, and `disclosure_rows`. It covers Unified and SideBySide at widths 24 and 40, collapsed and expanded, with wrapped Lines, context Lines, ReviewCards, a Draft chain, a Fold, and disclosures. The digests are the values of `6f9f09f`, and no later commit changes them.
- `38445a9` keeps Line owners out of `NavigationIndex.owners`. Every `owners` reader was checked: `find` reads `owners` only for an owner that is not a Line, and the other readers (`cardHeaderOwner` lookups, the Draft header jump, the resolved Thread disclosure) ask for owners that are not Lines. The build reserves `owners` from the count of the other rows.
- `d9947f0` adds `KeyLists` in `src/tui/key_lists.zig`. `NavigationIndex.spans`, `SearchProjection.source_rows`, and `SearchProjection.body_rows` use it. A build calls its source twice: the first pass numbers the keys and counts their entries, and the second pass writes each entry into one shared array at its key's cursor. Each list keeps the call order. `addSourceRow` is deleted. The new test "a NavigationIndex build allocates the same for any key count and grows no key list" fails on the per-key lists of `38445a9` with 2,049 allocations for 512 rows and 16,385 for 4,096 rows.
- `65c44b6` checks that Line rows add no `owners` entry. The build of `30afd1d` fails it with 4,096 entries. AGENTS.md has the rule.
- `027f456` restores the free count of the one-span growth test, which `d9947f0` dropped, and checks `find` for a missing Line key.

**Measurement.** Method of ticket 25, ReleaseFast, `[DEBUG-09]` marks in detached worktrees that are now removed. Runs alternated base, step 1, step 3 three times, then base and step 3 twice more, with 8 resizes, 8 toggles, and 8 Layout switches in each run. Thread CPU of the worker per rebuild, median [range], in ms. "Step 1" is `38445a9` (no Line owners). "Step 3" is `d9947f0` (KeyLists, with step 1). The 1-minute load average was 1.9 to 6.2 from other work, on the Apple M5 Pro with 18 cores.

| Rebuild | Side | n | Whole job | Projection | Projection faults | Projection allocations |
| --- | --- | --- | --- | --- | --- | --- |
| Resize, Unified | base | 40 | 91.3 [68.6, 99.9] | 40.2 [37.6, 45.1] | 6,051 | 382,339 |
| | step 1 | 24 | 89.6 [72.1, 97.2] | 36.2 [34.0, 49.3] | 5,404 | 382,341 |
| | step 3 | 40 | 83.3 [57.7, 89.2] | 28.1 [25.7, 31.7] | 4,809 | 15 |
| Disclosure toggle | base | 40 | 90.8 [67.9, 106.7] | 39.0 [36.4, 61.1] | 6,001 | 382,265 |
| | step 1 | 24 | 83.6 [62.6, 91.5] | 34.6 [31.3, 42.1] | 5,355 | 382,270 |
| | step 3 | 40 | 75.7 [56.2, 84.6] | 26.7 [25.0, 36.2] | 4,781 | 15 |
| Switch to SideBySide | base | 20 | 135.3 [105.5, 214.1] | 50.6 [48.4, 52.5] | 9,768 | 394,249 |
| | step 1 | 12 | 123.9 [99.3, 211.0] | 44.2 [42.4, 45.9] | 8,467 | 394,249 |
| | step 3 | 20 | 123.5 [100.6, 207.8] | 38.5 [37.6, 47.1] | 6,704 | 15 |
| Switch to Unified | base | 20 | 118.0 [93.3, 128.5] | 38.1 [36.1, 42.6] | 6,000 | 382,265 |
| | step 1 | 12 | 112.2 [86.4, 120.2] | 33.0 [32.4, 35.3] | 5,354 | 382,266 |
| | step 3 | 20 | 106.2 [81.9, 112.8] | 25.4 [24.8, 28.2] | 4,781 | 15 |

Against the baseline of the same runs, the projection is 30 percent lower for a Unified resize, 32 percent lower for a toggle, and 24 percent lower for a switch to SideBySide. Step 1 saves 4 to 7 ms of it, and step 3 saves 6 to 8 ms more. The 12,362 failed remaps of a SideBySide projection, the growth copies of key lists, went to 0.

Process CPU (`ps -o time=`) for 8 actions, sorted:

| Side | 8 resizes | 8 toggles | 8 Layout switches | RSS after the resizes | RSS after the switches |
| --- | --- | --- | --- | --- | --- |
| Base | 0.63, 0.74, 0.79, 0.82, 0.84 s | 0.77, 0.77, 0.83, 0.83, 0.88 s | 0.99, 1.12, 1.14, 1.18, 1.18 s | 406 to 413 MB | 507 to 514 MB |
| Step 1 | 0.73, 0.77, 0.81 s | 0.71, 0.77, 0.80 s | 1.00, 1.07, 1.11 s | 400 MB | 502 MB |
| Step 3 | 0.65, 0.69, 0.72, 0.73, 0.73 s | 0.62, 0.69, 0.72, 0.72, 0.76 s | 0.96, 0.97, 1.08, 1.08, 1.10 s | 391 MB | 493 MB |

The median process CPU of 8 resizes went from 0.79 to 0.72 s. The difference, 0.07 s, is smaller than the base range of 0.21 s, so the last target is not met as written. One base run at 0.63 s makes most of that range. A rank-sum test of the 5 and 5 runs gives U = 5, which is not significant at 5 percent (the limit is 2). The expected saving is about 8 × 12 ms = 0.1 s of about 0.75 s, so this criterion needs more runs or a quieter machine to show it.

Checks on the numbers:

- One diagnostic run for each side ran the fixed loop of 2 million xorshift steps before the projection. It took 3.4 [3.2, 3.6] ms on the base and 3.4 [3.0, 3.6] ms with step 3 for a resize, so the clock before the projection is the same.
- The visual row phase is unchanged (resize 24.0 against 24.2 ms). The Buffer phase is bimodal by the clock state, as in ticket 25. The whole job of a resize saves 8 ms and of a toggle 15 ms, so the saving does not move into another phase.
- The release of the projection on the Presentation thread went from 2.6 [1.2, 6.0] to 2.1 [1.3, 4.2] ms, so the saving does not move into the free path.
- Every measured rebuild logged a digest of its Buffer row tags and visual rows. Each rebuild kind had the same row counts and digest on all sides: 187,839 and 206,104 for Unified, 187,856 and 206,121 with the Draft expanded, 209,672 visual rows at 150 columns, and 183,464 and 264,856 for SideBySide.
- Limiter, inferred and not profiled: the remaining 4,800 faults of fresh projection memory (about 3.6 ms at 0.76 µs per fault), the hashing of about 370,000 `source_rows` keys and the `spans` keys, and the two passes over the rows.

**Checks.** `zig build test --summary all`: 58 of 58 steps, 1,677 of 1,677 tests. `zig fmt --check src build.zig tests` and every `tools/check_*.py`: exit 0. No `DEBUG-` line in the commits.

**Review.** The two-axis review (standards and spec) found no wrong lookup. `027f456` fixes the dropped free count and adds the missing Line key check. Kept as they are: the release-build panic in `KeyLists` when a source changes its call count (an unchecked index would corrupt memory instead), the repeated `sink.add` pairs of the production and oracle sources, and the move of `body_rows` and the oracle to `KeyLists`, so no per-key list remains in the projection.

**Open question.** Accept the result on the projection targets and the RSS, or run more alternating runs to settle the process CPU of 8 resizes?

### 2026-11-16 operator decision

The operator accepted the measured result and resolved this ticket with the process CPU criterion waived.
The three projection targets are met.
The median process CPU of 8 resizes fell by 0.07 s, which matches the expected saving of about 0.1 s but stays inside the run-to-run range of a busy machine.
[Ticket 01 of the enrichment rebuild follow-up](../../enrichment-rebuild-follow-up/issues/01-find-what-bounds-the-remaining-search-projection-cost.md) owns the remaining projection cost.

## Completion

- Change: `30afd1d` pins the projection lookups, `38445a9` keeps Line owners out of `NavigationIndex.owners`, `d9947f0` stores the key lists of `spans`, `source_rows`, and `body_rows` in one shared array through `KeyLists`, `65c44b6` adds the Line owner check and its AGENTS.md row, and `027f456` applies the review fixes.
- Result: the projection phase is 30 percent lower for a Unified resize, 32 percent lower for a disclosure toggle, and 24 percent lower for a switch to SideBySide, against a fresh baseline at `6f9f09f`. The table in the comment of 2026-11-16 has the full numbers.
- Checks: `zig build test` exits 0, `zig fmt --check src build.zig tests` passes, and every `tools/check_*.py` that `build.zig` runs passes.
- Review: the two-axis code review found no wrong lookup. `027f456` fixes its findings.

