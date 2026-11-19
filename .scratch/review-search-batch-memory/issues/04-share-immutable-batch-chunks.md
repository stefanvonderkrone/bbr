# 04: Share immutable Batch chunks

Status: needs-triage
Blocked by: 02
Source: [ticket 01](01-find-why-review-search-holds-gigabytes.md)

## Problem

When a source scan is accepted while a Buffer build still holds the Batch, Presentation makes a deep copy of the whole Batch (`old.clone` in the `.scanned` branch of the source scan completion in `src/tui/presentation.zig`).
Each accepted scan also allocates a new Occurrence array for the old and the new Occurrences together, and merges them.
At a 1 MiB budget the peak holds 2 full Batches: 966,772 small mappings and 18.2 GB footprint.
800 of 958 accepted scans copied the whole Batch: 30.7 million Occurrences and 98.8 million mmap calls (measured, `mem8-notes.md`).
This plausibly explains M30 finding 4, minutes of 100 percent CPU after a Review Search (inferred).
`Batch.retain` in `src/tui/search.zig` also takes a whole page for one reference count, and it decides the copy on the pointer, not on the count.

## Proposal

- A Batch is a list of immutable chunks in the flat layout of [ticket 02](02-store-a-batch-as-flat-arrays.md). An accepted scan appends one chunk and copies nothing.
- A reader, such as a Buffer build, retains the chunks it reads with a reference count. A chunk is freed when its last holder releases it.
- The ranked order is an index permutation over the chunks. A merge builds a new permutation from the old one and the ranked new chunk, in one allocation of known size.
- Decide on the reference count, not on the pointer. Keep the count beside the chunk list, not in its own page.

## Acceptance criteria

- [ ] A test counts the Occurrences copied during a scan stream and fails on the current code: no accepted scan copies an earlier chunk.
- [ ] A live run at 1 MiB and 256 MiB budgets shows the peak footprint and the CPU seconds before and after.
- [ ] Recheck M30 finding 4 at 80 rows.

## Comments

### 2026-11-19 filed

The operator filed this ticket from the diagnosis in ticket 01.

### 2026-11-19 rewritten

The operator chose immutable chunks in the flat layout of ticket 02 instead of a shared Batch with a deep copy.
