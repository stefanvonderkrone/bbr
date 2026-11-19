# 04: Share the Batch while a build holds it

Status: needs-triage
Blocked by: none
Source: [ticket 01](01-find-why-review-search-holds-gigabytes.md)

## Problem

When a source scan is accepted while a Buffer build still holds the Batch, `src/tui/presentation.zig` line 8857 makes a deep copy of the whole Batch.
At a 1 MiB budget the peak holds 2 full Batches: 966,772 small mappings and 18.2 GB footprint.
800 of 958 accepted scans copied the whole Batch: 30.7 million Occurrences and 98.8 million mmap calls (measured, `mem8-notes.md`).
This plausibly explains M30 finding 4, minutes of 100 percent CPU after a Review Search (inferred).
`Batch.retain` (`src/tui/search.zig` line 151) also takes a whole page for one reference count.

## Proposal

- Make Batch chunks immutable and shared, so a new scan adds a chunk and a holder keeps its old chunks.
- Decide on the reference count, not on the pointer.

## Acceptance criteria

- [ ] A test counts Batch copies during a scan stream and fails on the current code.
- [ ] A live run at 1 MiB and 256 MiB shows the peak footprint and the CPU seconds before and after.
- [ ] Recheck M30 finding 4 at 80 rows.

## Comments

### 2026-11-19 filed

The operator filed this ticket from the diagnosis in ticket 01.
