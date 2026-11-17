# 25: Size the search projection indexes and the visual rows before their builds

Status: resolved
Blocked by: none

## Summary

[Ticket 21](21-find-why-the-visual-rows-cost-more-without-a-candidate-build.md) found that the phases after the visual rows of every rebuild cause about 11,000 minor faults.
The triage of 2026-11-15 measured these phases.
`SearchProjection.create` causes all of the faults except 30. The File Tree build causes 30 faults and costs 0.2 ms.

The projection touches about 180 MB of fresh memory for each rebuild of the workload.
Most of that memory holds no data:

- `NavigationIndex.add` and `addSourceRow` make one `ArrayList` for each key, about 380,000 lists in each rebuild. The first append of a list reserves a cache line, which is 128 bytes, but most lists hold one entry of 8 or 32 bytes. These lists use about 42 MB.
- The `owners`, `spans`, and `source_rows` maps grow from empty to a capacity of 262,144 in the projection arena. An arena cannot free the table that a growth replaces, so each earlier table stays in the arena with no data in it.
- The projection arena is on `std.heap.page_allocator`. Each release unmaps it, so each rebuild maps new pages, and each page causes a fault the first time the build writes to it.

The fix sizes these structures before the loops: the three maps from the visual row count, and each per-key list for one entry.
The same change reserves the visual row array, which ticket 21 measured.
On the workload, the projection phase of a Unified resize goes from 52.0 to 36.8 ms, and the process CPU of 8 resizes goes from 0.93 s to about 0.80 s.

## Cause

### Where the faults are

The probe split the `rest` phase of ticket 21 into its parts.
The values are the medians of 24 Unified resizes, 3 runs at `8aceb0d`. All values are for the worker thread.

| Part | Thread CPU | Minor faults | Allocations | Remaps (succeeded / failed) | Bytes requested |
| --- | --- | --- | --- | --- | --- |
| `file_tree.build` | 0.2 ms | 30 | 523 | 341 / 29 | 0.6 MB |
| Projection rows (`Row`, 192 bytes each) | 4.0 ms | 2,437 | 1 | 0 / 0 | 39.9 MB |
| `NavigationIndex.build` (`owners`, `spans`) | 26.2 ms | 4,956 | 186,220 | 152 / 1 | 81.2 MB |
| Deletion rows | 3.5 ms | 642 | 1 | 0 / 0 | 10.5 MB |
| `source_rows`, `body_rows`, `disclosure_rows` | 17.4 ms | 2,938 | 195,712 | 4 / 0 | 48.1 MB |
| `indexDisclosures` | 0.8 ms | 0 | 5 | 0 / 0 | 0 |
| Whole `rest` phase | 52.2 ms | 11,004 | | | |

The bytes count each allocation and each successful growth, as a counting allocator inside the arena sees them.
A map growth in the arena is a new allocation, and the replaced table is never freed.
The projection arena maps 290 MB of capacity in 3 blocks. The build writes to about 180 MB of it, one fault for each 16 KB page.

A disclosure toggle has the same values within 0.1 ms.
A switch to SideBySide costs 55.7 ms in the projection, with 11,645 faults, because its 264,856 visual rows make the projection rows larger (50.9 MB).

### What a fault costs

A temporary sketch kept the arena of the released projection, reset it with `reset(.retain_capacity)`, and gave it to the next projection.
That sketch removed all projection faults and left the work unchanged.
It saved 0.93 µs for each removed fault in the projection phase (10,973 faults, 10.2 ms, one screening run), and 0.76 µs for each fault after the sizing fix (6,050 faults, 4.6 ms, 3 runs).
The lead of ticket 21 assumed 1.5 µs for each fault, so the faults cost about 9 ms of a resize, not 15 ms.

The release of the projection (`munmap` of its arena) costs about 3.7 ms of Presentation thread CPU on each rebuild, and the release of the job arena costs about 1.8 ms.
The faults and these releases come from the same cause: each rebuild uses new memory for the projection.

### The clock ramp

A fixed loop of 2 million xorshift steps ran before the `rest` phase in one diagnostic run of each side.
Its median was 3.2 ms on the baseline, 3.25 ms with the sizing, and 3.35 ms with the sizing, the retained arena, and the reservation.
So the core clock before the projection is the same on every side, and the saving in the projection is not a clock effect.

## What is inherent

- The projection must be built again for each resize, toggle, and Layout switch. Its keys map to visual row indexes, and a new width or a new disclosure moves every visual row after the change. No input of the projection is equal to the last build, unlike the corpus of ticket 07.
- The projection rows (39.9 MB) and deletion rows (10.5 MB) are one allocation each, with no growth. They fault because the memory is new. Only a retained arena removes those faults. See Rejected directions.

## What to build

1. `NavigationIndex.build` in `src/tui/frame.zig` reserves `owners` and `spans` for `rows.len` entries before its loop.
2. `SearchProjection.createWithAllocator` in `src/tui/presentation.zig` reserves `source_rows` for `visual_rows.len` entries before its index loop.
3. A new per-key list in `NavigationIndex.add` and `addSourceRow` gets a capacity of one entry (`.empty`, then `ensureTotalCapacityPrecise(a, 1)`), not the cache-line capacity of a first append. A second entry grows the list, as now.
4. `frame.buildVisualRowsWithOptions` reserves the visual row array before its loop with `ensureTotalCapacityPrecise`, as ticket 21 describes. The measured sketch reserved `rows.len + rows.len / 8`. Ticket 21 asks for `rows.len + rows.len / 2`, so that SideBySide (1.44 times the Buffer rows) does not grow either. The unused tail is virtual memory with no fault, and `toOwnedSlice` returns it to the arena.

The capacity of a map is a hint: a Buffer with more keys than visual rows grows the map, as now.
The orders that `occurrenceRows` and `NavigationIndex.find` read do not change, because each list keeps its entries in the same order.

A sketch of steps 1 to 4 at `8aceb0d` passed `zig build test --summary all` (exit 0, 56 of 56 steps, 1,665 of 1,665 tests).

## Measured effect

Three runs for each side, alternated, with 8 actions of each kind in each run. Thread CPU of the worker per rebuild, median [range], in ms.
"Sizing" is steps 1 to 3. "Retained" is the arena sketch that is rejected below.

| Rebuild | Side | n | Total | Projection | Faults in the job |
| --- | --- | --- | --- | --- | --- |
| Resize, Unified | baseline | 24 | 111.1 [84.9, 115.6] | 52.0 [51.3, 56.1] | 19,562 |
| | sizing | 24 | 96.1 [77.0, 99.4] | 36.8 [34.7, 38.3] | 14,638 |
| | sizing, retained, reservation | 24 | 91.3 [74.6, 95.5] | 33.8 [32.8, 38.8] | 6,948 |
| Disclosure toggle | baseline | 24 | 111.2 [102.0, 114.1] | 51.8 [50.4, 54.7] | 19,522 |
| | sizing | 24 | 95.8 [88.9, 99.5] | 36.5 [35.8, 43.0] | 14,570 |
| Switch to SideBySide | baseline | 12 | 140.4 [119.3, 226.7] | 55.7 [54.5, 57.3] | 27,999 |
| | sizing | 12 | 134.0 [104.6, 220.6] | 48.0 [47.5, 49.9] | 26,122 |
| Switch to Unified | baseline | 12 | 137.9 [127.9, 140.8] | 50.7 [49.9, 51.6] | 26,883 |
| | sizing | 12 | 121.3 [100.5, 124.3] | 35.8 [34.5, 39.2] | 21,930 |

Process CPU (`ps -o time=`) for 8 actions, three runs each:

| Side | 8 resizes | 8 toggles | 8 Layout switches | RSS after the resizes |
| --- | --- | --- | --- | --- |
| Baseline | 0.93, 0.93, 0.93 s | 0.99, 0.99, 0.99 s | 1.24, 1.25, 1.25 s | 552 MB |
| Sizing | 0.79, 0.80, 0.82 s | 0.86, 0.86, 0.87 s | 1.06, 1.12, 1.19 s | 473 MB |
| Sizing, retained | 0.77, 0.77, 0.78 s | 0.80, 0.80, 0.81 s | 1.08, 1.11, 1.12 s | 570 MB |
| Sizing, retained, reservation | 0.75, 0.76, 0.76 s | 0.77, 0.77, 0.80 s | 1.08, 1.10, 1.10 s | 518 MB |

The sizing saves 15.2 ms of the projection of a resize. About 4 ms of that are the 4,924 faults that it removes, and the rest is the hash map growth and the list growth that it removes.
The whole resize saves 15.0 ms, so the saving does not move into another phase.
The Presentation thread saves too: the release path of 8 resizes (projection and job arena) went from 34 to 40 ms to 27 to 29 ms, because the arenas are smaller.
Process CPU of 8 resizes falls by 0.11 to 0.14 s, about 14 percent.

In SideBySide the saving is smaller (7.7 ms), because most of its keys have two rows. A list of one entry then grows, and 4,164 and 8,198 remaps fail in the two indexes. [Ticket 09](09-make-the-search-projection-cheaper.md) step 3, a flat layout of the entries, removes these growths.

### The visual row reservation

With the reservation, the visual row phase of a Unified resize went from 27.0 to 24.7 ms, with 2,132 faults instead of 3,773, and one allocation with no failed remap.
The whole resize went from 92.4 to 91.3 ms, inside the range. Process CPU of 8 resizes went from 0.77 to about 0.76 s.
The RSS after the resizes went from 570 to 518 MB, because the job arena no longer keeps the replaced copy of the array.
The reservation is one line, and its effect on faults, allocations, and RSS shows in every rebuild, so it lands with this change.

## Rejected directions

- Keep the arena of the released projection for the next build. It removes the remaining 6,050 faults and saves about 4 ms of thread CPU for each resize and about 2 ms of Presentation thread CPU, but it keeps about 100 MB resident while bbr is idle (570 against 473 MB). The arena slot would also be new state shared between the Presentation thread and the worker. Measure it again after ticket 09, when the projection is smaller.
- Keep the job arena for the next build. It removes the faults of the Buffer and the visual rows (8,550 for each resize), but the buffer phase grew from 31.8 to 42.5 ms, and the process CPU did not change (0.76 to 0.79 s against 0.75 to 0.76 s without it). RSS grew to 629 MB.

## Method

Use the workload of [ticket 05](05-make-a-buffer-rebuild-faster.md): `bbr local fb701b11db249ad7e57779fd1fa859085b51b946 18362616348204d57f111e15ad7f22e1a841a9e3` from a checkout of this repository, ReleaseFast, tmux at 160 × 80, a separate `XDG_STATE_HOME` with mode `700`, and one Draft with 14 paragraphs.

- Resize: put the cursor on a Diff Line (row 4), then `tmux resize-window -x 150` and `-x 160`, 4 times each, 1.5 s apart. With the cursor on the File header, `actionAvailability` adds about 30 ms of Presentation thread CPU to each resize. See the comment of 2026-11-15.
- Disclosure toggle: Enter on the `[...]` row (row 15) expands the Draft. The expanded card has no `[...]` row. Enter on its last body row (row 33) collapses it and puts the cursor on row 16, so press `k` before the next Enter. 4 cycles make 8 toggles.
- Layout switch: `s`, 8 times, 2.5 s apart.

Put temporary `[DEBUG-25]` marks in `DisclosureBuild.buildFallible` and in `SearchProjection.createWithAllocator` in a detached worktree. Per part, record the thread CPU (`CLOCK_THREAD_CPUTIME_ID`), the minor faults (`getrusage`), and the calls through a counting allocator inside the projection arena. Run the projection arena on a counting allocator over the page allocator to count its blocks.
Alternate the baseline and the change, at least 3 runs per side. Record the process CPU of each action sequence with `ps -o time=`, the RSS after the resizes, and the load average.

## Acceptance criteria

- [x] A test builds the projection of Unified and SideBySide Buffers with wrapped Lines, ReviewCards, Drafts, folds, and disclosures. For every source key, body owner, and visual row, `occurrenceRows`, `NavigationIndex.find`, the `owners` lookups, `requiredDisclosures`, and `disclosure_rows` give the same result as before the change.
- [x] A test builds the visual rows of a Buffer at two widths in each Layout and gets the same rows as before the change.
- [x] On the workload, the projection phase of a Unified resize is at least 25 percent lower than the baseline of the same run, and its minor faults go from about 10,970 to about 6,050. The baseline of the triage is 52.0 ms.
- [x] On the workload, the visual row phase of a Unified resize makes one allocation and no failed remap, and a switch to SideBySide makes one allocation for its visual rows.
- [x] On the workload, the process CPU of 8 Unified resizes is at least 10 percent lower than the baseline of the same run. The baseline of the triage is 0.93 s.
- [x] No other phase grows by more than the run-to-run range, and the RSS after the resizes does not grow.
- [x] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [x] No `[DEBUG-25]` or `[DEBUG-t25]` line stays in the repository.
- [x] `zig build test` passes.

## Comments

### 2026-11-15 triage

**Question.** Ticket 21 left a lead: about 11,000 faults in the phases after the visual rows, maybe 15 ms of a 110 ms Unified resize. This triage finds where they come from, whether they are avoidable work, and one fix. It also decides the visual row reservation of ticket 21.

**Probe.** Temporary `[DEBUG-t25]` marks at `8aceb0d` in a detached worktree, now removed. Per phase and per part of the projection: thread CPU, wall time, minor faults, a counting allocator inside the arena (allocations, growths, failed growths, bytes), and a counting allocator under the projection arena and the job arena (blocks and their bytes). The probe also timed the release of the projection and of the job arena on the Presentation thread. Environment switches, one per sketch: sizing, retained projection arena, retained job arena, visual row reservation, and the clock loop.

**Runs.** One screening run of each sketch, then 3 runs each of baseline, sizing, sizing with a retained projection arena, the same with the reservation, and all sketches, alternated in this order. ReleaseFast on an Apple M5 Pro with 18 cores. The 1-minute load average was 0.7 to 2.9 from other work. Every resize was a `view` build, every toggle a `general` build. The Buffer rows were 187,839 (187,856 with the Draft expanded) and 183,481 in SideBySide, and the visual rows 206,104 or 209,672 by width, and 264,873 in SideBySide, on every side.

**Profile.** One `sample` run during 8 resizes with the cursor on the File header row put 275 samples in `Presentation.actionAvailability` on the Presentation thread. Its `yankRefusal` calls `selectedVersionUnavailableForFile`, which scans every Buffer row with a binary search for each row when the cursor is on no source Line. `Presentation.projection` runs it about five times for each event. With the cursor on a Diff Line, the process CPU of 8 resizes fell from 1.20 to 1.28 s to 0.93 to 0.97 s. This cost is outside the rebuild and outside this ticket. It needs its own ticket.

**Overlap.** [Ticket 09](09-make-the-search-projection-cheaper.md) owns the same phase. Steps 1 to 3 of this ticket are its step 1 and part of its step 3. Ticket 09 should be blocked by this ticket and take a new baseline after it: its step 2 (no `.line` owners) and the flat entry layout of its step 3 remain, and they also remove the SideBySide growths above. Do not merge the two: this ticket is small, measured, and lands the reservation of ticket 21. [Ticket 12](../../enrichment-rebuild-follow-up/issues/04-grow-the-search-projection-ranges-without-copies.md) is the projected ranges of an active search. The workload has no search, so this triage measured nothing of it, and it stays separate.

**Decision.** `ready-for-agent`. The faults are not inherent. About 45 percent of the bytes of the projection are capacity with no data in it, and the fresh mapping of each rebuild makes every page fault. The sizing removes the empty capacity. The retained arena would remove the rest of the faults, but its memory cost is larger than its saving now.

## Completion

### Change

- `1c21725` pins the projection lookups and the visual rows of 9601be3. The test "search projection lookups match the 9601be3 baseline in both Layouts" builds collapsed and expanded Buffers with wrapped Lines, ReviewCards, a Draft chain, folds, and disclosures, in Unified and SideBySide at widths 24 and 40, and an empty Buffer. It hashes `occurrenceRows`, `source_rows`, `NavigationIndex.find`, the `owners` lookups, `requiredDisclosures`, and `disclosure_rows` for every source key and visual row, and compares each digest with the value of 9601be3. It also checks with a plain row scan that each source row list is ascending, shows its key, and covers every shown Line. Every SideBySide fixture has keys with two rows. The test "visual rows match the 9601be3 baseline at two widths in both Layouts" does the same for the visual rows.
- `9d786d8` is steps 1 to 4. The visual row array reserves `rows.len + rows.len / 2`, because a switch to SideBySide has 1.44 times the Buffer rows. A new per-key list in `NavigationIndex.add`, `addSourceRow`, and `body_rows` reserves one entry. The tests "a narrow Unified Line grows beyond the visual row capacity hint without leaks" and "a SideBySide replacement grows beyond the source key capacity hint without leaks" exceed each hint under `checkAllAllocationFailures`. The test "source row lists grow and release every failed allocation outside an arena" covers the non-arena caller of `addSourceRow`.
- `dd5e550` adds the growth tests "visual rows build in one allocation without a growth copy in both Layouts" and "a NavigationIndex whose keys each have one span grows nothing" in `src/tui/frame.zig`, and extends the Buffer row rule in `AGENTS.md`. At 9601be3 the first test fails with 2 allocations and the second with 20 replaced tables.

### Measurement

Method of this ticket, ReleaseFast, `[DEBUG-t25]` marks in detached worktrees that are now removed. 6 runs for each side, alternated base, change, base, change, with 8 resizes, 8 toggles, and 8 Layout switches in each run. Thread CPU of the worker per rebuild, median [range], in ms. The 1-minute load average was 1.4 to 9.9 from other work (an Android emulator and other sessions) on the Apple M5 Pro with 18 cores.

| Rebuild | Side | n | Total | Projection | Visual rows | Faults in the job | Visual row allocations / failed remaps |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Resize, Unified | baseline | 48 | 108.6 [82.7, 116.3] | 53.0 [50.3, 59.0] | 26.2 [18.2, 30.5] | 19,562 | 2 / 1 |
| | change | 48 | 93.9 [66.1, 103.2] | 39.7 [36.1, 46.4] | 23.5 [16.1, 26.0] | 12,998 | 1 / 0 |
| Disclosure toggle | baseline | 48 | 105.5 [83.7, 110.7] | 51.8 [50.0, 61.2] | 24.9 [18.6, 27.6] | 19,523 | 2 / 1 |
| | change | 48 | 90.5 [66.6, 100.1] | 38.7 [36.2, 48.9] | 22.4 [16.1, 24.8] | 12,929 | 1 / 0 |
| Switch to SideBySide | baseline | 24 | 143.0 [110.3, 227.4] | 55.7 [52.6, 61.5] | 19.9 [17.9, 22.6] | 27,999 | 1 / 0 |
| | change | 24 | 133.9 [108.2, 224.1] | 52.0 [48.0, 65.6] | 19.0 [17.2, 21.0] | 26,122 | 1 / 0 |
| Switch to Unified | baseline | 24 | 133.3 [106.4, 147.7] | 51.6 [48.1, 58.1] | 17.1 [16.3, 18.8] | 26,883 | 1 / 0 |
| | change | 24 | 119.3 [93.1, 130.5] | 39.9 [35.6, 44.7] | 16.8 [15.7, 19.6] | 21,930 | 1 / 0 |

The projection faults of a resize went from 10,974 to 6,050. In SideBySide they went from 11,645 to 9,768, and the saving is smaller because most keys have two rows, as the triage found.

Process CPU (`ps -o time=`) for 8 actions, sorted:

| Side | 8 resizes | 8 toggles | 8 Layout switches | RSS after the resizes | RSS after the switches |
| --- | --- | --- | --- | --- | --- |
| Baseline | 0.79, 0.83, 0.93, 0.94, 0.95, 0.97 s | 0.85, 0.88, 0.97, 0.98, 0.99, 1.00 s | 1.14, 1.17, 1.21, 1.27, 1.28, 1.31 s | 538 to 539 MB | 613 to 615 MB |
| Change | 0.64, 0.79, 0.79, 0.80, 0.80, 0.81 s | 0.67, 0.73, 0.80, 0.83, 0.88, 0.90 s | 1.04, 1.06, 1.11, 1.17, 1.19, 1.20 s | 404 to 411 MB | 505 to 512 MB |

The median process CPU of 8 resizes went from 0.935 to 0.795 s, 15 percent lower.

Checks on the numbers:

- The Buffer phase is bimodal on both sides, about 13 ms or about 30 ms for each build, by the clock state of the core. Its medians are equal (29.4 and 29.7 ms for a resize), so the change moves no cost into it. The whole resize saves 14.7 ms, and the projection and the visual rows save 13.3 and 2.7 ms, so the saving does not move into another phase of the job.
- The release of the projection on the Presentation thread went from 3.7 [1.4, 5.3] to 2.2 [1.0, 4.7] ms (n = 156), so the saving does not move into the free path.
- One diagnostic run for each side ran the fixed loop of 2 million xorshift steps before the projection. It took 2.6 to 3.5 ms on the baseline and 2.6 to 3.7 ms with the change, so the clock before the projection is the same on both sides.
- Each measured rebuild logged a digest of its Buffer row tags and its visual rows. Every rebuild kind and width had the same row counts and the same digest on both sides.
- Limiter, inferred from the per-part probe of the triage and not profiled again: the remaining 6,050 faults of fresh projection memory (about 4.6 ms at 0.76 µs per fault), the about 380,000 per-key list allocations, and their hashing. Ticket 09 owns that layout.

### Checks

- `zig build test --summary all`: exit 0, 56 of 56 steps, 1,672 of 1,672 tests.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`, `check_benchmark_metrics.py`, `check_diagnostics.py`, `check_search_index.py`, `check_navigation_fields.py`: exit 0.
- `git grep "DEBUG-"` in `src`, `tools`, `tests`, and `build.zig`: no match.

### Review

The two-axis review (standards and spec) found no wrong behavior. Commit `0f7835e` adds the why-comments it asked for. Kept as they are: the three short get-or-create blocks (one helper across two files and two map types is not simpler), the 9601be3 digest pins, and the one-entry reservation of `body_rows`, which follows the same rule. The empty Buffer fixture is Unified only.

### Follow-up

[Ticket 27](../../enrichment-rebuild-follow-up/issues/07-find-the-other-rebuild-lists-that-grow-from-empty.md) lists the other rebuild lists and maps that grow from empty, for triage.
