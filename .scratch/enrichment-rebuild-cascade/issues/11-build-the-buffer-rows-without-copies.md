# 11: Build the Buffer rows without copies

Status: resolved
Blocked by: none

## Summary

The triage of tickets 07 to 09 on 2026-11-13 found the largest remaining cost of a Unified Buffer rebuild.
About 28 % of the CPU samples of a Unified rebuild are `memcpy` of the Buffer row array.
Both Buffer builds of a rebuild pay this cost: the Buffer itself and the second Buffer of the search candidates.

## Evidence

All paths are in `src/tui/buffer.zig`.

- `buildWithComments` appends each Row to `rows` through `opts.scratch_allocator`.
  `BuildOptions.scratch_allocator` defaults to `std.heap.page_allocator`.
- On macOS, each growth of that array on the page allocator copies the whole array.
- At the end, `buildWithComments` copies the rows once more with `allocator.dupe(Row, rows.items)`.

The runner measured worker CPU per rebuild at commit `60d7553` on the workload of [ticket 05](05-make-a-buffer-rebuild-faster.md).
The runs alternated with a prototype.
The load average was 2.7 to 6.8 on 18 cores.
The prototype reserved the row array once in the build arena and dropped the final copy.

| Rebuild | Baseline median | Prototype median | Change |
| --- | --- | --- | --- |
| Resize, Unified | 172 ms | 126 ms | −27 % |
| Toggle, Unified | 120 ms | 102 ms | −15 % |
| Switch to SideBySide | 401 ms | 351 ms | −12 % |

The prototype kept the Buffer and visual row counts unchanged.

## What to build

A Buffer build grows its row array without a copy of the whole array on each growth, and returns the rows without a final copy.
For example, the build reserves the row array once from a count or an upper bound, in the allocator that owns the result.
The Buffer keeps the same rows in the same order.

## Acceptance criteria

- [x] A test shows that a Buffer build returns the same rows in the same order as before, for Unified and SideBySide, with Comments, Drafts, folds, and disclosures.
- [x] No `dupe` of the row array remains at the end of `buildWithComments`.
- [x] On the ticket 05 workload, the median worker CPU of a Unified resize is at least 20 % lower than a baseline from the same session, with alternated runs.
- [x] The Buffer and visual row counts are the same as the baseline.
- [x] `zig build test` passes.

## Comments

### 2026-11-13 filed

Filed from the triage report of tickets 07 to 09. Tickets 07 and 08 state their targets relative to a baseline of the same run, so they hold in any order with this ticket.

## Completion

### Change

The commit `tui/buffer: build the rows without copies` on this branch changes `src/tui/buffer.zig`, `AGENTS.md`, and the tickets 11 and 12:

- The result allocator of `buildWithComments` owns the row list from the first append. Every caller passes an arena, and `Buffer` has no `deinit`, so the rows live as long as that arena.
- `rowCapacity` estimates the row count from the Hunk lines, the shown blob lines of a whole-file build, the expanded disclosures, and the bodies of the Comments and Drafts. The build reserves the list once with that estimate. A low estimate lets the list grow in the arena. Each growth then copies the list, and the arena keeps the old block until it resets. A high estimate keeps the unused tail in the arena. Nobody measured the retained memory.
- Every append, also in `Weave` and `emitStatusPlaceholders`, uses the result allocator. `toOwnedSlice` replaces the final `dupe`. An arena shrinks the list in place (`std/heap/ArenaAllocator.zig`, `resize`), so the return does not copy.
- `BuildOptions.scratch_allocator` keeps its default and now holds only the ReviewCard projection scratch.
- No code keeps a pointer into the growing list. The build keeps only row indexes, and `indexCards` runs on the final slice.

### Same rows

A temporary test wrote a deep text dump of each Row (tag, Line text, kind, numbers and display version, pair sides, disclosure kind, count and state, card part, role, depth and text, sections, header paths, placeholder states) for 32 fixtures at `ea10317` and with the change.
The fixtures cover both Layouts, card widths 24 and 80, Comments with a resolved Thread and Replies, multi-paragraph Drafts, collapsed and expanded folds and disclosures, the search candidate options, whole-file builds of both versions, an isolated File, and status placeholders.
Both dumps have 1,870 rows, and `diff` found no difference. The temporary test is not in the commit, because a test that pins every row of a fixture fails on each intended row change.
The existing row-order tests in `src/tui/buffer.zig` and `src/tui/render.zig` still pass. The permanent test "rowCapacity holds every row of a Buffer build" builds the same fixture kinds and checks that the estimate holds every row.

### Live measurement

The workload and method are those of [ticket 05](05-make-a-buffer-rebuild-faster.md), with `[DEBUG-t11]` marks in separate detached worktrees at `ea10317` (baseline) and `ea10317` plus this change (result).
The runs alternated baseline and result four times each, with 8 actions of each kind per run. The load average was 1.1 to 3.9 on 18 cores.
Wall time and thread CPU time agree within 1 ms.
The numbers are macOS numbers. On macOS the page allocator cannot grow a mapping in place. Linux can grow it with `mremap`, so the saving there can be smaller.

Worker CPU per rebuild, median (range):

| Rebuild | n per side | Baseline | Result | Change |
| --- | --- | --- | --- | --- |
| Disclosure toggle, Unified | 32 | 105.8 ms (94.1 to 114.8) | 87.7 ms (74.8 to 92.2) | −17.1 % |
| Resize, Unified | 32 | 147.2 ms (137.5 to 163.1) | 111.3 ms (103.5 to 122.8) | −24.4 % |
| Layout switch to Unified | 16 | 146.9 ms (136.7 to 161.9) | 108.8 ms (100.4 to 114.8) | −25.9 % |
| Layout switch to SideBySide | 16 | 366.9 ms (357.6 to 383.4) | 321.9 ms (316.6 to 334.3) | −12.3 % |

Phase medians in ms, baseline → result:

| Rebuild | buffer | candidates | corpus | visual | projection |
| --- | --- | --- | --- | --- | --- |
| Disclosure toggle | 40.0 → 17.9 | none | none | 17.9 → 20.0 | 47.4 → 49.4 |
| Resize | 39.9 → 18.3 | 40.2 → 22.2 | 5.0 → 5.9 | 14.3 → 15.6 | 47.6 → 48.6 |
| Switch to Unified | 40.6 → 18.2 | 39.8 → 21.9 | 5.0 → 5.8 | 14.5 → 15.5 | 47.7 → 48.4 |
| Switch to SideBySide | 150.5 → 128.0 | 142.0 → 120.0 | 4.9 → 5.0 | 17.9 → 17.9 | 51.5 → 51.0 |

Only the two Buffer build phases lost time, 18 to 23 ms each, in both Layouts. The other phases moved by 1 to 2 ms.
The projection phase (about 48 ms) now limits a Unified rebuild, and the change block matching of ticket 08 limits a SideBySide rebuild.

Buffer rows and visual rows were the same on both sides: 187,839 and 206,104 for Unified, 187,856 and 206,121 with the Draft expanded, 209,672 visual rows at 150 columns, and 183,464 and 264,856 for SideBySide.
Only the expected build kinds ran: `general` for a toggle and `view` for a resize and a Layout switch.

Process CPU for 8 actions, four runs each:

| Action | Baseline | Result |
| --- | --- | --- |
| Disclosure toggle | 0.90, 0.86, 0.88, 0.93 s | 0.75, 0.72, 0.75, 0.76 s |
| Resize | 1.25, 1.22, 1.24, 1.27 s | 0.94, 0.96, 0.96, 0.96 s |
| Layout switch | 2.15, 2.08, 2.12, 2.17 s | 1.79, 1.79, 1.78, 1.80 s |

### Benchmark

`zig build bench` on macOS, ReleaseFast, five alternating runs per side, 15 samples per run after two warmups. Median (range) in ms. The checksums are the same on both sides.

| Case | Baseline | Result |
| --- | --- | --- |
| `buffer_projection_300_files_50000_lines` | 4.67 (3.74 to 5.19) | 3.62 (2.78 to 4.15) |
| `comment_anchors_0` | 5.33 (3.85 to 5.43) | 2.79 (2.16 to 3.96) |
| `comment_anchors_100` | 7.13 (6.97 to 8.89) | 4.91 (4.85 to 5.06) |
| `comment_anchors_2000` | 17.99 (17.24 to 21.27) | 14.45 (14.06 to 14.98) |

The ranges of `buffer_projection_300_files_50000_lines` and `comment_anchors_0` overlap, so these cases alone show no clear difference.

### Mistake class

Two classes have more than one real case.

- A large list that grows on `std.heap.page_allocator`: the Buffer rows, and the projected Review Search ranges in `SearchProjection.projectOccurrences` through `projectRanges`. Before `e995fc96`, the full Review Search projection also grew on the page allocator.
- A finished result copied once more: the Buffer rows, and the ranges in `SearchProjection.project`. Commit `c667f4ea` already removed range copies, and `ae569f94` removed ReviewCard row copies.

The fix for the Buffer build is in its structure: the result allocator owns the rows from the start, and the build reserves them once.
The test "a Buffer build without ReviewCards builds its rows in the result storage" passes a failing allocator as scratch storage. With the scratch row list of `ea10317` it fails with `OutOfMemory` at `rows.append(opts.scratch_allocator, ...)`.
A line check does not work for the class. The past growth came through a parameter default, so no `page_allocator` text was on the append line. A ban on `dupe` would also reject deliberate copies, such as the Span copy of the highlighter that lowers retained memory.
`AGENTS.md` has a row for the rule and its tests. [Ticket 12](12-grow-the-search-projection-ranges-without-copies.md) holds the search projection cases, which nobody has measured.

### Checks

- `zig build test --summary all`: exit 0, 52 of 52 steps, 1,630 of 1,630 tests.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.
- `python3 tools/check_benchmark_metrics.py`: pass.
- No `[DEBUG-t11]` line in the repository.

### Review

The two-axis code review found no correctness problem. Each append uses the result allocator, and the failing-allocator test fails on the old scratch row list.
This change fixes its findings: the missing review result, an `AGENTS.md` row that claimed checks for the reserve and the return, a test name that claimed more than its check, the text about a low estimate, and two numbers.
The review also named the constants in `rowCapacity` and its copy of the scope logic of the build. They stay, because the estimate needs no exact bound and the capacity test covers each fixture kind.
