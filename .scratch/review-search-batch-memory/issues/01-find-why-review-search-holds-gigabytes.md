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
