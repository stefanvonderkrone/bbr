# 26: Check the Selected Version availability without a scan of all rows

Status: needs-triage
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
