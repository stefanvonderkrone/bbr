# 01: Find why Review Search holds gigabytes

Status: needs-triage
Blocked by: none

## Problem

A live test on 2026-11-18 ran Review Search on a large local Review: 479 Files, 187,827 Buffer rows, about 160,000 occurrences for the query `e`. It ran in ReleaseFast in tmux at 160 × 80 on a machine with 64 GB of RAM.

| Point | Process RSS |
| --- | --- |
| After the Session load, before Review Search | 385 MB |
| During the scans, peak of the samples | 14 to 17 GB |
| Peak memory footprint (with compressed memory) | 18 to 24 GB |
| After the Overlay closes, on `main` | 8.3 to 8.5 GB |

RSS is resident memory at the moment of one sample, not a sum over time.
The same numbers appear at the default File cache budget of 256 MiB, so the File cache does not cause them.
All File content of the Review is 22.6 MiB. The Buffer rows are about 71 MB (376 bytes each).
8 GB for 160,000 occurrences is about 50 KB for each occurrence.

Stack samples put the work in `search.Batch.clone` and `search.Batch.deinit`. On `main`, each released Review Search hold queues a cache build, which clones and frees the whole Batch on the main thread.

After the Overlay closes, `main` keeps about 8 GB until the process ends. The raw data is in the notes of the live test (`live-cub-notes.md` in the operator's temp folder).

## What to find

- What one occurrence and one Batch hold, in bytes, and how many Batch copies live at the peak.
- Why about 8 GB stays after the Overlay closes: a leak, an allocator that keeps freed pages, or a retained Batch.
- Whether this explains M30 finding 4 (100 percent CPU for minutes after a Review Search) and the peak RSS follow-up of M28.

## Acceptance criteria

- [ ] A measured breakdown of the peak and of the memory after close, with the method.
- [ ] A defect ticket for each cause, with a test or a benchmark that shows it.

## Comments

### 2026-11-18 filed

The operator asked for this ticket after the live test of the cache update branch.

### 2026-11-18 two Batch owners found by the cache update fixes

- The published Frame (`Published.worker_frame`) kept the Review Search snapshot of its build. After a source scan replaced the Batch, the Frame was the only owner of the old Batch until the next Buffer build. Commit `d916df00` on branch `cache-update-during-review-search` releases the snapshots at publication. That removed the 13 to 14 GB after close on that branch. It does not change the 8.5 GB floor.
- `acceptReviewSourceScanned` clones the whole old Batch before each merge when `old.references != null`. `Batch.retain` sets `references` once and never clears it, so after the first Buffer build every source scan clones the whole Batch, also when no build holds it any more. A `sample` during the scans shows most active main thread time in `__munmap` and `__mmap` under `Batch.clone` and `Batch.deinit`. Checking the reference count instead of the pointer is likely to remove most of the copies (inferred, not tried).
