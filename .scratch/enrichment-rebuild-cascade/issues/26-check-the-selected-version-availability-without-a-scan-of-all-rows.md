# 26: Check the Selected Version availability without a scan of all rows

Status: resolved
Blocked by: none

## Summary

The triage of [ticket 25](25-measure-the-page-faults-of-the-phases-after-the-visual-rows.md) found a cost on the Presentation thread, outside the Buffer rebuild.
`Presentation.actionAvailability` in `src/tui/presentation.zig` calls `yankRefusal`.
When the cursor is on no source Line, for example on a File header, `yankRefusal` calls `selectedVersionUnavailableForFile`.
That function scans every Buffer row and runs a binary search for each row.
`Presentation.projection` calls `actionAvailability` about five times for each event.

On the workload of ticket 05, one `sample` run during 8 resizes put 275 samples in `actionAvailability` with the cursor on the File header row.
That is about 30 ms of Presentation thread CPU for each resize.
With the cursor on a Diff Line, the process CPU of 8 resizes fell from 1.20 to 1.28 s to 0.93 to 0.97 s.
The cost also applies to every other event while the cursor is on such a row, not only to a resize. This is inferred from the code and was not measured.

## What the triage decides

- Measure the cost per event with the cursor on a File header, on a Diff Line, and on a ReviewCard row, with process CPU and the Presentation thread CPU.
- Find whether the answer can come from data that the Buffer build already has, for example a per-File flag, or whether one result per projection is enough instead of about five scans.
- Set a measurable target with a baseline, and write acceptance criteria that include process CPU.

Use the workload and the method of ticket 25.

## Cause

`yankRefusal` asks one question when the cursor is on a row with no source Line: does the cursor's File have a status placeholder that is not `.empty` for the Selected Version?
`selectedVersionUnavailableForFile` answers it with a scan of all Buffer rows, and a `fileIndexForRow` binary search for each row.
On the workload that is 187,839 rows for each call.
`actionAvailability` runs 5 times for a `presentation_done` event and 6 times for a key or a resize event.

The Buffer build already knows the answer.
`buildWithComments` in `src/tui/buffer.zig` emits the status placeholder rows of a File in one place, directly one after the other, after the File header and its File-level cards.
No other code adds a `.status_placeholder` row, and `buildWithComments` is the only Buffer builder.

## Fix

1. `FileRow` in `src/tui/buffer.zig` records the row range of the status placeholders of its File, which `buildWithComments` knows when it emits them. An empty range means no placeholder.
2. One Buffer method gives the status placeholder rows of a File. It finds the `FileRow` by File index with the binary search of `fileHeaderRow`.
3. `selectedVersionUnavailableForFile` reads only those rows. The result does not change.

The cost goes from O(Buffer rows × log Files) to O(log Files) for each call.
One result for each projection, instead of 5 or 6 calls, is not part of this fix: after step 3 a call costs about as much as on a Diff Line. Measure it again after the change.

## Measured baseline

Three runs at `6236c4c`, ReleaseFast, with temporary `[DEBUG-26]` marks in a detached worktree. The marks record the thread CPU of each event of the Presentation thread loop in `src/tui/app.zig` and the thread CPU inside `actionAvailability`.
Each run measures 8 resizes and 8 cursor moves (`j` and `k`, alternated) with the cursor on the File header (row 1, the moves go to the hunk header and back), on a Diff Line (row 4, moves between rows 3 and 4), and on a ReviewCard body row (row 7). The load average was 1.0 to 2.5 on the Apple M5 Pro with 18 cores.

| Cursor | Action | Process CPU of 8 actions | Presentation thread CPU | In `actionAvailability` |
| --- | --- | --- | --- | --- |
| File header | 8 resizes | 1.06, 1.07, 1.09 s | 491 to 507 ms | 447 to 466 ms (88 calls) |
| File header | 8 moves | 0.37, 0.39, 0.39 s | 365 to 391 ms | 360 to 386 ms (48 calls) |
| Diff Line | 8 resizes | 0.77, 0.77, 0.77 s | 47 to 48 ms | 0.06 ms |
| Diff Line | 8 moves | 0.01 s | 8 to 10 ms | 0.05 ms |
| ReviewCard row | 8 resizes | 0.78, 0.78, 0.79 s | 48 to 50 ms | 0.07 ms |
| ReviewCard row | 8 moves | 0.01 s | 8 to 10 ms | 0.06 ms |

So one cursor move on the File header costs about 47 ms of Presentation thread CPU, and 46 ms of it is the scan, 6 calls of about 8 ms.
A resize costs about 57 ms more on the File header than on a Diff Line.
No event arrives while bbr is idle (no log line in 5 s after the moves), so the cost is per event, not per tick.
The process CPU difference of 8 resizes (0.30 s) is less than the scan time (0.45 s). Inferred, not measured: the busy Presentation thread keeps the cores at a high clock, so the worker build of the same resize runs faster (see the clock ramp of [ticket 21](21-find-why-the-visual-rows-cost-more-without-a-candidate-build.md)).

## Target

- `actionAvailability` costs at most 0.1 ms for each call on the File header, as on a Diff Line.
- The process CPU of 8 resizes on the File header is at least 20 percent lower than the baseline of the same run, about the value on a Diff Line.
- The process CPU of 8 cursor moves on the File header is at most 0.05 s.

## Acceptance criteria

- [x] Tests through `Presentation` pin the yank refusal and the other availability results for a cursor on a File header, a status placeholder, a Diff Line, and a ReviewCard row, with the selected side loaded, unavailable, and empty, in Unified and SideBySide, and in a Buffer with several Files where another File has an unavailable placeholder. The tests pass before and after the change.
- [x] No code scans all Buffer rows to answer a question about one File's status placeholders.
- [x] The targets above hold on the workload, with at least 3 alternated runs for each side.
- [x] The process CPU and the Presentation thread CPU on a Diff Line and on a ReviewCard row do not grow by more than the run-to-run range.
- [x] No `[DEBUG-26]` line stays in the repository.
- [x] `zig build test` passes.

## Comments

### 2026-11-16 triage

**Question.** Is the scan of ticket 25 a real cost per event, and can the answer come from data that the Buffer build already has?

**Probe.** Temporary `[DEBUG-26]` marks at `6236c4c` in a detached worktree log, for each event of the loop in `src/tui/app.zig`, the event kind, the thread CPU of the whole iteration, the thread CPU in `actionAvailability`, and its call count. A script runs the three cursor positions in one bbr process and reads the process CPU with `ps -o time=` around each action sequence.

**Result.** The cost is real and is on every event while the cursor is on a row with no source Line: about 8 ms for each `actionAvailability` call, 5 or 6 calls for each event. The screening run and the two runs after it agree within 3 percent. With the cursor on a Diff Line or a ReviewCard row, `actionAvailability` costs less than 0.01 ms for each call.

**Decision.** `ready-for-agent`. The Buffer build records the status placeholder rows of each File, and the check reads only those rows. A single result per projection is not needed if the first step meets the target.

## Completion

### Change

- `8b8b595` pins the results first. The test "yank availability keeps unavailable content within its File in both layouts and scopes" drives two Files through File Enrichment. The old side of one File is unavailable, and that File comes before or after the other File. The test runs in Unified and SideBySide, in the Changes and WholeFile scopes, and for both Selected Versions. On each File header, hunk header, status placeholder, Diff Line, and ReviewCard header, it checks the yank, inline Comment, and Suggestion refusals and the error of a refused yank. The test "yank availability treats an empty whole-file side as no source in both layouts" pins an empty side as `.no_source`. A check that always answers false, or that reads the placeholders of every File, fails the first test.
- `00361e4` is the fix. `FileRow` records the row range of its File's status placeholders, which `buildWithComments` emits one after the other. `Buffer.statusPlaceholders` returns those rows, and `selectedVersionUnavailableForFile` reads only them. `fileHeaderRow` and `statusPlaceholders` share one binary search over `file_rows`. The Status Placeholder tests in `src/tui/buffer.zig` check, for each File of each binary and unavailable fixture, also in an isolated File view, that `statusPlaceholders` gives exactly the placeholder rows of that File.
- `f1ce8c3` applies the review: the build appends each `FileRow` after its status placeholders, so `status_placeholders` needs no default, and a new builder must set it. The check also counts a loop over `0..rows.len`, and the benchmark Buffer digest includes the range.
- `e9bd737` adds `tools/check_row_scans.py` and its rule in `AGENTS.md`. See the `correct` result below.
- `0dc438a` files the follow-ups.

### Measurement

Method of the triage, ReleaseFast, `[DEBUG-26]` marks in detached worktrees that are now removed. Three runs for each side, alternated base, change, base, change, base, change. Each run measures 8 resizes and 8 cursor moves at each cursor position in one bbr process. Median [range].

| Cursor | Action | Side | Process CPU of 8 actions | Presentation thread CPU | In `actionAvailability` (calls) |
| --- | --- | --- | --- | --- | --- |
| File header | 8 resizes | baseline | 1.05 [0.85, 1.11] s | 479 [302, 526] ms | 435 [262, 481] ms (88) |
| | | change | 0.76 [0.59, 0.78] s | 49 [42, 50] ms | 0.06 [0.03, 0.06] ms (88) |
| File header | 8 moves | baseline | 0.33 [0.15, 0.38] s | 321 [148, 383] ms | 317 [144, 378] ms (48) |
| | | change | 0.01 [0.00, 0.01] s | 8.9 [5.8, 10.0] ms | 0.05 [0.04, 0.06] ms (48) |
| Diff Line | 8 resizes | baseline | 0.79 [0.61, 0.80] s | 51 [39, 52] ms | 0.06 ms |
| | | change | 0.79 [0.77, 0.80] s | 49 [49, 51] ms | 0.06 ms |
| Diff Line | 8 moves | baseline | 0.01 s | 8.4 [2.9, 9.8] ms | 0.05 ms |
| | | change | 0.01 s | 9.7 [9.6, 10.0] ms | 0.06 ms |
| ReviewCard row | 8 resizes | baseline | 0.80 [0.59, 0.82] s | 51 [38, 52] ms | 0.07 ms |
| | | change | 0.79 [0.77, 0.80] s | 48 [48, 51] ms | 0.07 ms |
| ReviewCard row | 8 moves | baseline | 0.01 s | 9.6 [2.9, 10.2] ms | 0.06 ms |
| | | change | 0.01 s | 8.5 [8.4, 8.5] ms | 0.06 ms |

On the File header, the process CPU of 8 resizes is 28 percent lower (1.05 to 0.76 s), and one cursor move costs about 1.1 ms of Presentation thread CPU instead of about 40 ms. A call of `actionAvailability` costs about 0.001 ms on every cursor position. The Diff Line and ReviewCard rows did not change outside the run-to-run range.

Checks on the numbers:

- The cursor was at the expected row before and after each sequence on every run (`1/187839`, `4/187839`, `7/187839`), and every sequence logged the same events and calls (16 events and 88 calls for 8 resizes, 8 events and 48 calls for 8 moves) on both sides.
- The saving of the Presentation thread on the File header (about 430 ms for 8 resizes) is larger than the saving of process CPU (about 0.29 s). Inferred, not measured: the busy Presentation thread kept the cores at a high clock, so the worker build ran faster on the baseline. The change makes the File header cost the same as a Diff Line, which is the floor of this fix.
- The 1-minute load average was 1.0 to 4.8 from other work on the Apple M5 Pro with 18 cores. The first baseline run had the highest load and the lowest baseline values (0.85 s and 0.15 s), and it is still far above every run of the change.
- Limiter after the change, from the probe: `actionAvailability` is no longer visible. A resize is bound by the worker rebuild of tickets 05 and 25, and a cursor move by the paint.

### Correct

The mistake class is a query about one File that scans every Buffer row or visual row and asks each row for its File, although the Buffer records each File's rows. It happened before: tickets `performance-implementation/08` (`263c36b`) and `performance-implementation/10` (`33d5d46`), `m21-buffer-review-search/15` (`72a7f35`, `e6a3c91`, `26ad200`), `enrichment-rebuild-cascade/02` and `03`, ticket 22 (`hasBodyOwner`, still open), and this ticket.

- Architecture: the Buffer answers questions about one File. `fileHeaderRow` and `statusPlaceholders` share one lookup of `FileRow`, and a new per-File fact is a new `FileRow` field that the build sets.
- Lint: `tools/check_row_scans.py` counts each production `fileIndexForRow` call in the body of a `for` loop over a whole `rows` or `visual_rows` array or over `0..rows.len`, per file, against `tools/row_scan_baseline.txt`. A check with no baseline would need 7 exceptions now (two Frame builds that visit every row, the Review Search oracle, two worker searches, and two test helpers outside `test` blocks), so a ratchet is the honest level. The check fails on the source of 6236c4c with 8 calls against the baseline of 7 and names line 14593, the old loop.
- `AGENTS.md` has the rule and its enforcement. A `while` loop over all rows and a scan without `fileIndexForRow`, such as `hasBodyOwner`, are conventions.

### Checks

- `zig build test --summary all`: exit 0, 58 of 58 steps, 1,674 of 1,674 tests.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`, `check_benchmark_metrics.py`, `check_diagnostics.py`, `check_search_index.py`, `check_navigation_fields.py`, `check_row_scans.py`: exit 0.
- `git grep "DEBUG-"` in `src`, `tools`, `tests`, and `build.zig`: no match.

### Review

The two-axis review (standards and spec) found no wrong behavior and no placeholder row outside its range. Applied: no default for `status_placeholders`, the `0..rows.len` loop shape, a count of calls instead of lines, an isolated File view in the Buffer tests, and the range in the benchmark Buffer digest. Kept as they are: the enrichment block that the two new tests repeat (a shared helper would cover many older tests too), and the long `AGENTS.md` row, which follows the other rows. The empty side is pinned with one File only, because only the WholeFile scope has an empty side and the leak case is pinned with unavailable content. A call through a helper and a `while` loop are not checked.

### Follow-up

- [Ticket 28](../../enrichment-rebuild-follow-up/issues/08-ask-the-buffer-about-one-file-in-the-worker-searches.md): the worker searches that remain in the baseline.
- [Ticket 29](../../enrichment-rebuild-follow-up/issues/09-compute-the-action-availability-once-for-each-event.md): the 5 or 6 availability calls for each event, which matter only with a large Selection now.
