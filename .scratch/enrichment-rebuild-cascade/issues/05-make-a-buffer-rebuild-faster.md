# 05: Make a Buffer rebuild faster

Status: resolved
Blocked by: none

## Summary

Every disclosure toggle, File isolation, Layout switch, resize, Draft change, and File Enrichment result rebuilds the whole Buffer on a worker.
Tickets 01 to 04 reduce how often a rebuild runs.
This ticket reduces the CPU cost of one rebuild.

The triage measured the cost at commit `46b33d4` on a fixed local workload.
A Unified rebuild costs about 0.3 seconds of worker CPU, and a SideBySide rebuild costs about 0.6 seconds.
More than half of a Unified rebuild is the visual row build, which measures each grapheme of each row through vaxis again on each rebuild.
A prototype ASCII fast path in `frame.wrapEnd` cut the visual row build from about 195 ms to about 15 ms, with the same visual row counts.

## Workload

The workload needs no network and no Credential, so its input is fixed:

- `bbr local fb701b11db249ad7e57779fd1fa859085b51b946 18362616348204d57f111e15ad7f22e1a841a9e3`, run from a checkout of this repository.
- A ReleaseFast build (`zig build -Doptimize=ReleaseFast`).
- tmux at 160 × 80, with `window-size manual`, `status off`, and a separate `XDG_STATE_HOME` with mode `700`.
- 479 Files. The Unified Buffer has 187,845 rows and 206,110 visual rows. The SideBySide Buffer has 183,470 rows and 264,862 visual rows.
- One Draft with 14 paragraphs, so that its ReviewCard has a disclosure (`[...] (enter to expand)`). Without a Draft, the workload has no disclosure, because a local diff has no threads and no context run long enough to fold. Create the Draft with `i` on a Diff Line, type `para 1`, Enter, Enter, `para 2`, and so on, then `ctrl-s`. The Draft stays in the `XDG_STATE_HOME`.

Wait until the Session load and the first File Enrichment rebuilds end, and the CPU is idle, before you measure.

The rebuild kinds and their keys:

| Rebuild | Key | `DisclosureBuild.Kind` |
| --- | --- | --- |
| Disclosure toggle | Enter on the `[...]` row of the Draft card | `.general` |
| Resize | `tmux resize-window -x 150`, then `-x 160` | `.view` |
| Layout switch | `s` | `.view` |
| File Enrichment result | `]` to a File that is not enriched yet | `.enrichment` |

## Measurement method

The triage put temporary timing marks, tagged `[DEBUG-t05]`, in `DisclosureBuild.buildFallible` in `src/tui/presentation.zig`.
Each mark reads the thread CPU clock (`CLOCK_THREAD_CPUTIME_ID`) and the monotonic clock.
The log line records the kind, the Buffer rows, the visual rows, the total, and these phases:

- `buffer`: `buildBuffer`.
- `candidates`: `buffer.buildSearchCandidates`. Only `.view`, `.enrichment`, `.cache_update`, `.draft_save`, `.draft_mutation`, `.review_destination`, and `.card_destination` builds run it.
- `corpus+scan`: `BufferSearchCorpus.create` and the scans of an accepted or typed Buffer Search query.
- `visual`: `frame.buildVisualRowsWithOptions`.
- `tree`: `file_tree.build`.
- `projection`: `SearchProjection.create`.

The wall time and the thread CPU time of each rebuild agree within 1 percent, so a rebuild is CPU-bound on one core.
The process CPU time (`ps -o time=`) over 8 actions agrees with the sum of the worker times within about 10 percent, so the worker build is the cost of the action.

The triage ran each binary twice, in the order baseline, prototype, baseline, prototype, with 8 actions of each kind in each run.
The machine has 18 cores and had a load average of about 3 from other work.
The numbers are medians, with the range of all runs.

## Baseline at `46b33d4`

Worker CPU per rebuild:

| Rebuild | n | Median | Range | buffer | candidates | visual | projection |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Disclosure toggle, Unified | 16 | 296 ms | 287 to 304 ms | 45 | none | 198 | 49 |
| Resize, Unified | 16 | 338 ms | 320 to 363 ms | 42 | 41 | 194 | 51 |
| Layout switch to Unified | 8 | 346 ms | 320 to 349 ms | 59 | 42 | 190 | 49 |
| Layout switch to SideBySide | 8 | 602 ms | 581 to 658 ms | 154 | 153 | 231 | 55 |

The phase columns are medians in milliseconds. `corpus+scan` is about 5 ms, and `tree` is under 1 ms.
About 40 File Enrichment rebuilds in one earlier session cost 315 to 343 ms each, with the same phase split as a Unified resize.

Process CPU for 8 actions: disclosure toggle 2.57 s and 2.63 s, Layout switch 3.93 s and 3.77 s, resize 2.85 s and 2.72 s.

## Hotspots

A `sample` profile of the process during 14 Unified resizes put 3,343 samples in `DisclosureBuild.buildFallible`:

| Function under `buildFallible` | Share |
| --- | --- |
| `frame.buildVisualRowsWithOptions` | 55.7 % |
| `presentation.SearchProjection.create` | 16.6 % |
| `buffer.buildSearchCandidates` | 13.1 % |
| `buffer.buildWithComments` | 11.8 % |
| Other | 2.8 % |

- In the visual row build, 78 percent of the samples are in `render.nextVaxisGrapheme`, which `frame.wrapEnd` calls once for each grapheme through `CellMetrics.next`. The time goes to `vaxis.unicode.graphemeIterator`, the grapheme break state machine, and `gwidth.gwidth`. Most source text in the workload is printable ASCII, where each byte is one grapheme of one cell.
- `buildSearchCandidates` spends 86 percent of its samples in its own call of `buildWithComments`. It builds a second full Buffer with every disclosure expanded, and then reads the source lines from it.
- `SearchProjection.create` spends its time in `addSourceRow` (the `SourceRowKey` map) and in the `NavigationIndex` owner maps (`getOrPutContext`, `grow`, and `NavigationIndex.add`).

A second profile with the prototype, during SideBySide Layout switches and resizes, ranked the rest:
`buildWithComments` 36.9 %, `buildSearchCandidates` 35.4 %, `SearchProjection.create` 18.9 %, and the visual row build 6.0 %.
About 43 percent of those samples are the own time of the SideBySide change block matching, `emitSideBySideChangeBlock`, which the compiler inlined into `Weave.emitSideBySideHunk` at `src/tui/buffer.zig` line 1588. Its call of `diff.intraline.diff` adds about 7 percent.
A SideBySide rebuild runs this matching twice, once for the Buffer and once for the search candidates.

## The guessed directions

The profile supports these conclusions about the directions that the first version of this ticket guessed:

- The cell width of each grapheme is the largest cost. A cache of row widths is not necessary. A fast path for printable ASCII removes 93 percent of the phase without state that must stay current.
- A rebuild that reuses the parts of other Files would also save the work, but it needs a new design of the Buffer ownership. This ticket does not need it to meet its target.
- Hash map growth is a small part. `grow` has about 25 of the 555 samples of `SearchProjection.create`. A size known before the build can help that phase, but it cannot make the rebuild much faster.

## Prototype

The triage tested the first direction in a separate worktree at `46b33d4`, then removed the worktree.
At the start of `frame.wrapEnd`, when `text[start..]` is printable ASCII (each byte from `0x20` to `0x7e`, the same test as `isNarrowAscii` in `src/tui/cell_metrics.zig`):

- If the rest has at most `width` bytes, it returns `text.len`.
- Otherwise it returns the position after the last space at or before `start + width`, if that position is after `start`.
- Otherwise it returns `start + width`.

This gives the same result as the grapheme loop for this text, because each byte is one grapheme of one cell and the only whitespace is the space.
Tab and other control bytes are not printable ASCII, so they still take the grapheme loop.

Worker CPU per rebuild with the prototype, measured in the same runs as the baseline:

| Rebuild | n | Median | Range | Change | visual |
| --- | --- | --- | --- | --- | --- |
| Disclosure toggle, Unified | 16 | 126 ms | 100 to 129 ms | −57 % | 17 ms |
| Resize, Unified | 16 | 161 ms | 149 to 176 ms | −52 % | 14 ms |
| Layout switch to Unified | 8 | 170 ms | 157 to 182 ms | −51 % | 14 ms |
| Layout switch to SideBySide | 8 | 385 ms | 374 to 406 ms | −36 % | 16 ms |

The Buffer rows and the visual rows were the same as in the baseline for each rebuild.
Process CPU for 8 actions: disclosure toggle 1.21 s and 1.23 s, Layout switch 2.33 s and 2.26 s, resize 1.41 s and 1.35 s.

## What to build

Add a fast path for printable ASCII text to the line wrap in `src/tui/frame.zig`, as in the prototype.
`wrapEnd` serves the Unified rows and, through `makeVisualHalf`, the SideBySide halves, so both Layouts get it.

- The visual rows must be exactly the same as the grapheme loop gives, for every `CellMetrics`. The fast path assumes that a printable ASCII byte is one grapheme of one cell. `CellMetrics.width` already makes this assumption.
- Check the line once, not once for each wrapped segment. The prototype checked `text[start..]` again for each segment.
- Do not cache widths across rebuilds.

The work splits into independent wins. This ticket is the first one. Each later win can be a child ticket with the same workload and method:

1. This ticket: the ASCII fast path in the visual row build.
2. Build the search candidates without a second full Buffer. `buildSearchCandidates` could reuse the candidates of the previous rebuild when its inputs did not change, or read the source lines without the row weave. This saves about 41 ms on a Unified rebuild and about 150 ms on a SideBySide rebuild. A disclosure toggle does not build candidates, so it gets nothing.
3. Make the SideBySide change block matching cheaper. It is about 150 ms of each SideBySide Buffer build, and win 2 removes the second run.
4. Make `SearchProjection.create` cheaper. It is about 50 ms of every rebuild, mostly in its hash maps.

After this ticket, a Unified rebuild of about 160 ms is buffer 42 to 62, candidates 41, projection 48, visual 14, and corpus 5.
So wins 2 and 4 together can save at most about 90 ms more on a Unified rebuild.

## Benchmark

The acceptance measure is the workload above, with the method above.
Use temporary timing marks tagged `[DEBUG-05]` in a separate detached worktree, and remove them before the commit.
Run the baseline binary and the changed binary in alternation, at least twice each, with 8 actions of each kind in each run.

Also add a benchmark to `zig build bench`.
The existing `visual_rows_wide_50000` and `visual_rows_narrow_50000` cases in `src/benchmark/p1_actions.zig` use `CellMetrics.bytes`, so they do not measure the vaxis grapheme cost.
`src/benchmark/main.zig` already imports `vaxis`.
Add a case with a `CellMetrics` that does the same as `render.nextVaxisGrapheme`, for example `visual_rows_terminal_wide_50000`.
Add a case with non-ASCII rows too, so that the benchmark shows that the grapheme loop did not get slower.

## Acceptance criteria

- [x] A frame test compares the fast path with the grapheme loop. It covers printable ASCII lines shorter than, equal to, and longer than the width, lines with no space, a space at the wrap column, a trailing space, a line that is ASCII up to a non-ASCII grapheme, tab and other control bytes, and CR LF. Each case gives the same visual rows as the grapheme loop, in Unified and SideBySide.
- [x] The new `zig build bench` cases exist and print a checksum that is the same before and after the change.
- [x] On the workload, the median worker CPU of a Unified disclosure toggle and of a Unified resize is at least 45 percent lower than the baseline of the same run. The triage baseline is 296 ms and 338 ms.
- [x] On the workload, the median worker CPU of a Layout switch to SideBySide is at least 30 percent lower than the baseline of the same run. The triage baseline is 602 ms.
- [x] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [x] The completion records the runs, the medians, the ranges, the phase split, and the process CPU of 8 actions, before and after.
- [x] No `[DEBUG-05]` or `[DEBUG-t05]` line stays in the repository.
- [x] `zig build test` passes.

## Comments

### 2026-11-12 triage

The runner triaged the ticket at the operator's request and set it to `ready-for-agent`.
The CPU sample in the first version of this ticket was from `main` at commit `3b29039` on PullRequest A, before tickets 01 to 03. This version replaces it with the measurements above.

The triage chose `bbr local` over PullRequest A because a local Review needs no network and has no Bitbucket rate limit, as tickets 02 and 03 found.
The triage chose the ASCII fast path over a width cache because the prototype meets the target with no state across rebuilds.

The prototype binary does not prove that the wrap boundaries are equal. It only showed equal row counts. The frame test in the acceptance criteria must prove it.

The second profile also showed about 666 samples on the Presentation thread in `Presentation.actionAvailability`, at the `activeFile` calls, during 20 seconds of Layout switches and resizes.
That cost is outside the worker rebuild and outside this ticket. A later ticket can measure it.

## Completion

### Change

- `1567999` moves the vaxis adapter into `src/tui/terminal_cell_metrics.zig`. `render.zig`, a render test, and the benchmarks share it, and the benchmark module exports it as `tui.terminal_cell_metrics`. The visual row cases now use it: `visual_rows_terminal_wide_50000`, `visual_rows_terminal_narrow_50000`, `visual_rows_terminal_side_by_side_50000`, and `visual_rows_terminal_unicode_50000`. They replace `visual_rows_wide_50000` and `visual_rows_narrow_50000`, which measured `CellMetrics.bytes`.
- `dd2764d` adds `CellMetrics.ascii_is_narrow` and `CellMetrics.narrowAscii`. The adapter states that each printable ASCII byte is one grapheme of one cell, and `width` and the Line wrap both read that statement. For a printable ASCII Line, the wrap ends after the last space that fits, else at the width. Other Lines keep the grapheme loop.
- `843e6c6` puts the check in `WrapLine.init` in `src/tui/frame.zig`, so the visual row build checks each Line once and the flag always belongs to its text.
- `19a9562` adds `tools/check_benchmark_metrics.py` and its tests, and a row in `AGENTS.md`. See the class result below.

### Wrap equality

The frame test "a printable ASCII Line wraps at the same positions as the grapheme loop" builds visual rows with a CellMetrics and with the same CellMetrics with `ascii_is_narrow` off, and compares the Buffer index, the source range, the continuation, and the halves of each visual row.
It runs the terminal metrics and `CellMetrics.bytes`, Unified and SideBySide (both halves, one half, and halves of different lengths), every body width from 1 to the Line length plus 2, the listed cases of the acceptance criteria, and 400 generated Lines.
A second test checks the wrap positions of six printable ASCII Lines against literal rows.
Both tests failed on a fast path that also used a space just past the width, which is one reading of the triage prototype.
The test "vaxis measures each printable ASCII byte before ASCII or the end as one grapheme of one cell" in `src/tui/terminal_cell_metrics.zig` checks the base of the fast path for every printable byte, alone and before each ASCII byte.

### Live measurement

The workload and method are the ones above, with `[DEBUG-t05]` marks in separate detached worktrees at `a1d029a` (baseline) and `19a9562` (result).
The runs alternated baseline, result, three times each, with 8 actions of each kind per run. A resize action is one `tmux resize-window`, to 150 or back to 160.
The machine has 18 cores, and its load average was 1.6 to 3.5 from other work.
Wall time and thread CPU time agree within 1 ms, so each rebuild is CPU-bound on one worker core.

Worker CPU per rebuild:

| Rebuild | n per side | Baseline median (range) | Result median (range) | Change |
| --- | --- | --- | --- | --- |
| Disclosure toggle, Unified | 24 | 298.1 ms (276.5 to 305.9) | 124.0 ms (106.7 to 127.8) | −58.4 % |
| Resize, Unified | 24 | 337.3 ms (327.3 to 352.0) | 163.3 ms (154.0 to 175.6) | −51.6 % |
| Layout switch to Unified | 12 | 336.6 ms (317.3 to 359.9) | 166.5 ms (155.3 to 175.8) | −50.5 % |
| Layout switch to SideBySide | 12 | 573.5 ms (545.1 to 583.3) | 371.6 ms (367.0 to 381.2) | −35.2 % |

Phase medians in ms, baseline → result:

| Rebuild | buffer | candidates | corpus | visual | tree | projection |
| --- | --- | --- | --- | --- | --- | --- |
| Disclosure toggle | 59.6 → 58.6 | none | none | 192.0 → 18.1 | 0.2 → 0.2 | 46.6 → 46.4 |
| Resize | 59.6 → 59.2 | 37.4 → 38.8 | 4.8 → 4.9 | 188.2 → 14.3 | 0.2 → 0.2 | 47.3 → 46.9 |
| Switch to Unified | 55.6 → 61.3 | 38.4 → 38.8 | 4.8 → 5.0 | 189.8 → 14.2 | 0.2 → 0.2 | 47.4 → 47.1 |
| Switch to SideBySide | 162.1 → 160.8 | 140.6 → 139.2 | 4.9 → 4.8 | 215.3 → 17.3 | 0.2 → 0.2 | 51.5 → 50.6 |

The visual phase lost 174 to 198 ms, and the whole rebuild lost the same amount, so the change removed only that work.
The other phases did not change. They now limit a rebuild: buffer, candidates, and projection are about 145 ms of a Unified resize, and buffer and candidates are 300 ms of a SideBySide switch.
The remaining visual phase is the append of about 206,000 visual rows of 168 bytes.

Buffer rows and visual rows were the same on both sides: 187,839 and 206,104 for Unified, 187,856 and 206,121 with the Draft expanded, 209,672 visual rows at 150 columns, and 183,464 and 264,856 for SideBySide.
Only the expected build kinds ran during the actions: `general` for a toggle and `view` for a resize and a Layout switch.

Process CPU for 8 actions, three runs each:

| Action | Baseline | Result |
| --- | --- | --- |
| Disclosure toggle | 2.45, 2.41, 2.42 s | 1.03, 0.99, 1.01 s |
| Resize | 2.78, 2.77, 2.76 s | 1.37, 1.41, 1.38 s |
| Layout switch | 3.69, 3.70, 3.72 s | 2.22, 2.25, 2.19 s |

One more result run at `843e6c6` gave a toggle median of 123.6 ms, a resize median of 166.4 ms, and a SideBySide median of 378.4 ms, with the same row counts.

### Benchmark

`zig build bench`, ReleaseFast, two alternating runs per side, the median of 15 samples per run. Baseline is `1567999`, result is `843e6c6` and `dd2764d`:

| Case | Baseline | Result | Checksum, both sides |
| --- | --- | --- | --- |
| `visual_rows_terminal_wide_50000` | 93.9, 90.2 ms | 0.82 to 0.85 ms | `5f5a2f49ab0fb96b` |
| `visual_rows_terminal_narrow_50000` | 109.4, 108.2 ms | 1.53, 1.54 ms | `f17b464f3a1e0962` |
| `visual_rows_terminal_side_by_side_50000` | 184.7, 183.0 ms | 1.68 to 1.89 ms | `31dea13c8fdb7a4a` |
| `visual_rows_terminal_unicode_50000` | 71.9, 72.5 ms | 72.1 to 72.7 ms | `5b2e258b3887f92a` |

The Unicode case shows that the grapheme loop did not get slower.

### Mistake class

A benchmark measured a proxy of the app path, so the cost that dominates a rebuild showed in no benchmark.
`visual_rows_wide_50000`, `visual_rows_narrow_50000`, and `file_tree_tallies_2000` passed `CellMetrics.bytes` (`13c58b5`), `comment_anchors_*` took the `.bytes` default of `BuildOptions`, and `cell_width_ascii_1m` kept its own copy of the vaxis adapter (`f3ed2b3`).
The architecture fix gives the adapter one owner that the benchmarks import.
The type-level fix needs the `.bytes` defaults gone, which touches every test that builds a Buffer or a Presentation, so [ticket 10](10-require-the-cell-metrics-of-every-buffer-build.md) holds it.
Until then, `tools/check_benchmark_metrics.py` rejects `.bytes` in the benchmark sources and names `tui.terminal_cell_metrics`. It fails on lines 83 and 116 of `src/benchmark/p1_actions.zig` at `a1d029a`.
The second candidate class, a fast path that drifts from its slow path, has no past occurrence in the history, so it adds no rule. The wrap test covers this fast path.

### Child tickets

- [07](07-build-the-search-candidates-without-a-second-buffer.md): build the search candidates without a second Buffer.
- [08](08-make-the-side-by-side-change-block-matching-cheaper.md): make the SideBySide change block matching cheaper.
- [09](09-make-the-search-projection-cheaper.md): make `SearchProjection.create` cheaper.
- [10](10-require-the-cell-metrics-of-every-buffer-build.md): require the cell metrics of every Buffer build.

### Checks

- `zig build test --summary all`: exit 0, 52 of 52 steps, 1,628 of 1,628 tests.
- `zig fmt --check src build.zig`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.
- No `[DEBUG-05]` or `[DEBUG-t05]` line in the repository.

### Review

The two-axis code review found no hard violation and no wrong behavior. It confirmed each edge of the fast path against the grapheme loop.
`843e6c6` fixes its findings: the flag that could belong to another text, the missing one-half pairs and `.bytes` runs in the test, an inline import, a test-local `std`, and the missing files in `src/tui/IMPLEMENTATION.md`.
The review also named the new `ascii_is_narrow` field as possible speculative generality. It stays, because it states the assumption that `width` and the wrap share, and the wrap test uses it as its oracle.
It called the benchmark check and the replaced benchmark names scope creep. They are the class fix that the runner asked for, and the replaced cases measured the proxy.
