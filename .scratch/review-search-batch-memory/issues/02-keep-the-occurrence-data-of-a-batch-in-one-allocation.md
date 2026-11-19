# 02: Keep the Occurrence data of a Batch in one allocation

Status: needs-triage
Blocked by: none
Source: [ticket 01](01-find-why-review-search-holds-gigabytes.md)

## Problem

Each Review Search Occurrence takes 3 allocations from `std.heap.page_allocator`: `old_path`, `new_path`, and `ranges`.
The page allocator maps one whole 16 KiB page for each allocation, which holds about 27 bytes.
One Occurrence needs about 81 bytes of heap data but costs 49,304 bytes.
After a Review Search with 127,514 Occurrences closes, 382,542 such pages hold 5.98 GB of the 8.7 GB footprint (measured, `mem8-notes.md`).

Sites: `src/tui/search.zig` lines 51 to 67 (`Location.clone` duplicates both paths) and 119 to 146 (`Batch.clone`), `src/tui/presentation.zig` line 8843 (each scanned part is cloned into the page allocator), and `src/tui/app.zig` line 1067 (the worker scans with the page allocator).

## Proposal

- Give each Batch one arena or slab for its Occurrence data, and keep the Buffer arenas off malloc.
- Drop the path copies, because `file_index` already names the File.

## Acceptance criteria

- [ ] A test or benchmark shows the bytes for each Occurrence before and after.
- [ ] A live run on the large local Review shows the footprint after close and at the peak, before and after.
- [ ] A test build that swapped the page allocator for `c_allocator` gave 8.5 GB to 2.6 GB after close and 10.7 GB to 3.2 GB at the peak. The fix reaches at least that.

## Comments

### 2026-11-19 filed

The operator filed this ticket from the diagnosis in ticket 01.
