# 02: Store a Batch as flat arrays

Status: needs-triage
Blocked by: none
Source: [ticket 01](01-find-why-review-search-holds-gigabytes.md)

## Problem

Each Review Search Occurrence owns its own heap data: `location.old_path`, `location.new_path`, `ranges`, and `definition_ranges`.
`makeOccurrence` in `src/tui/search.zig` duplicates both paths for each Occurrence, and `scanLiteral` allocates a temporary `positions` array for each match.
`Batch.clone` copies each Occurrence one by one. Presentation clones each accepted scan into `std.heap.page_allocator` (`src/tui/presentation.zig`, the `.scanned` branch of the source scan completion), and the worker scans with the page allocator too.
The page allocator maps one whole 16 KiB page for each allocation, which holds about 27 bytes.
One Occurrence needs about 81 bytes of heap data but costs 49,304 bytes.
After a Review Search with 127,514 Occurrences closes, 382,542 such pages hold 5.98 GB of the 8.7 GB footprint (measured, `mem8-notes.md`).

An arena or a slab would remove the page waste but keep the per-Occurrence ownership and the 152-byte struct that ranking moves.

## Proposal

Data-oriented layout of a Batch:

- **Struct of arrays.** The sort and merge keys (`score`, `corpus_order`, `file_index`, the line) live in their own arrays. Cold fields, such as `column` and `candidate_scalars`, live in separate arrays.
- **One range pool for each Batch.** An Occurrence holds a `u32` start and a small length into the pool instead of a slice. `definition_ranges` uses the same pool or a second one.
- **No path copies.** A reader gets the paths from the Session through `file_index`. Verify first that a Batch never outlives the Session that its `session_epoch` names.
- **Ranking as an index permutation** of `u32`, not by moving Occurrence structs.
- **Known counts.** A clone or a merge knows the number of Occurrences and ranges in advance, so it allocates each array once and copies with `@memcpy`. A scan does not know its count in advance, so it grows the flat arrays with amortized growth. A scan takes no allocation for each match.
- Keep the Buffer arenas off malloc. A `c_allocator` swap test build moved them to malloc and raised the load footprint from 374 MB to 582 MB.

Estimate (arithmetic, not measured): about 30 to 40 bytes for each Occurrence, so 127,514 Occurrences take about 5 MB instead of 6 GB.

## Acceptance criteria

- [ ] A test counts the allocations of a scan, a clone, and a merge, and fails on the current code. A clone and a merge take a fixed number of allocations. A scan takes at most a logarithmic number, from the amortized growth of its arrays, never one or more for each Occurrence.
- [ ] A test or benchmark shows the bytes for each Occurrence before and after.
- [ ] A live run on the large local Review shows the footprint after close and at the peak, and the scan times, before and after. A test build that swapped the page allocator for `c_allocator` gave 8.5 GB to 2.6 GB after close and 10.7 GB to 3.2 GB at the peak. The fix reaches at least that.
- [ ] Buffer Search and Review Search tests pass unchanged, or each changed test names the reason.

## Comments

### 2026-11-19 filed

The operator filed this ticket from the diagnosis in ticket 01.

### 2026-11-19 rewritten

The operator chose a data-oriented layout instead of one arena or slab for each Batch.
