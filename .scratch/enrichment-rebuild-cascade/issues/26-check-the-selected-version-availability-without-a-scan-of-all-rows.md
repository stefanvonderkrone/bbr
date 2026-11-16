# 26: Check the Selected Version availability without a scan of all rows

Status: claimed
Claimed by: /Volumes/Work/t3-code/enrichment-rebuild-cascade (poteto-mode run 2026-11-16)
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

- [ ] Tests through `Presentation` pin the yank refusal and the other availability results for a cursor on a File header, a status placeholder, a Diff Line, and a ReviewCard row, with the selected side loaded, unavailable, and empty, in Unified and SideBySide, and in a Buffer with several Files where another File has an unavailable placeholder. The tests pass before and after the change.
- [ ] No code scans all Buffer rows to answer a question about one File's status placeholders.
- [ ] The targets above hold on the workload, with at least 3 alternated runs for each side.
- [ ] The process CPU and the Presentation thread CPU on a Diff Line and on a ReviewCard row do not grow by more than the run-to-run range.
- [ ] No `[DEBUG-26]` line stays in the repository.
- [ ] `zig build test` passes.

## Comments

### 2026-11-16 triage

**Question.** Is the scan of ticket 25 a real cost per event, and can the answer come from data that the Buffer build already has?

**Probe.** Temporary `[DEBUG-26]` marks at `6236c4c` in a detached worktree log, for each event of the loop in `src/tui/app.zig`, the event kind, the thread CPU of the whole iteration, the thread CPU in `actionAvailability`, and its call count. A script runs the three cursor positions in one bbr process and reads the process CPU with `ps -o time=` around each action sequence.

**Result.** The cost is real and is on every event while the cursor is on a row with no source Line: about 8 ms for each `actionAvailability` call, 5 or 6 calls for each event. The screening run and the two runs after it agree within 3 percent. With the cursor on a Diff Line or a ReviewCard row, `actionAvailability` costs less than 0.01 ms for each call.

**Decision.** `ready-for-agent`. The Buffer build records the status placeholder rows of each File, and the check reads only those rows. A single result per projection is not needed if the first step meets the target.
