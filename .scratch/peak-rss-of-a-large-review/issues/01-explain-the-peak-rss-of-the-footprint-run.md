# 01: Explain the peak RSS of the footprint run

Status: ready-for-agent
Type: research
Blocked by: none
Origin: [M28 spec](../../m28-full-review-file-cache-evaluation/SPEC.md), where this ticket was ticket 05.

## Question

The footprint run in [M28 ticket 02](../../m28-full-review-file-cache-evaluation/issues/02-run-the-baseline-on-the-five-pullrequests.md) reports `peak_rss_bytes=855785472`.
That value is 816 MiB.
The File cache holds at most 35,373,616 bytes, which is 33.7 MiB.
So about 780 MiB of the peak has no known owner.

Which owners hold that memory, and how much does each one hold?

This ticket is a research question, not M28 implementation work.
The M28 decision "no change" does not depend on the answer.
The File cache is at most 33.7 MiB of the peak.
Do not investigate it inside M28.

## Candidates

- The Highlighter and the tree-sitter parsers, with their trees and scratch memory.
- The Review Search state. S1 opens no Review Search, so confirm that this state is empty.
- The benchmark harness itself, such as its sample arrays and its HTTP client.
- Allocator memory that the process freed but did not return to the operating system.

The Session and its Diff Buffer are a fifth candidate that the measurement must also cover.

## Measurement

Measure offline first.
Build a Review with a File count and File sizes like PullRequest A.
The local run files of M28 ticket 02 give the File count.
A local Git history or a fixture on `FakeHttpClient` can supply the Files.
Count the live bytes and the peak bytes of each owner with a counting allocator for each owner.
Record the RSS at the same points, so the measurement shows the part that no allocator counts.
Run the measurement against live Bitbucket only if the offline Review does not show the peak.
A live run follows the run guide of M28 ticket 02 and records no PullRequest id.

## Acceptance criteria

- [ ] A table splits the peak RSS by owner, and one row holds the part that no owner counts.
- [ ] The answer states whether the measurement ran offline or live, and why.
- [ ] The answer names the largest owner and states whether it grows with the File count or the File size.
- [ ] The answer states whether the largest owner needs its own ticket.
- [ ] The recorded output holds no PullRequest id, source text, File path, query text, Comment text, or URL.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Agent brief

Answer the question with the cheapest measurement that splits the peak by owner.
Change no production code. Measurement code stays in the benchmark or in a test.

1. Read how the benchmark measures the peak.
   `peakRssBytes` in `src/benchmark/file_cache.zig` reads `getrusage` `maxrss`.
   That value is the high-water mark of the whole process lifetime, not the memory at the end of S1.
   A snapshot at the end of the run can miss a transient peak.
2. Read which allocator the benchmark uses.
   The benchmark builds as ReleaseFast and links libc.
   So `std.process.Init.gpa` is `std.heap.c_allocator`, see `callMain` in `std/start.zig` of Zig 0.16.0.
   The macOS allocator can keep freed pages resident, so the peak can hold memory that no owner still uses.
3. First try a split without new code.
   Run S1 on a large Review with `MallocStackLogging=1`.
   Sample `vmmap --summary` and `heap` on the process every few seconds, and keep the sample with the largest resident size.
   This split separates malloc memory from thread stacks and mapped files, and `heap` groups malloc memory by type.
   If this split names one owner that holds most of the 780 MiB, record it and stop.
4. Only if step 3 names no owner, follow the "Measurement" section with a counting allocator for each owner.
5. The benchmark has only the `remote` mode.
   An offline run needs a new fixture Review on `FakeHttpClient`, so prefer a live run when the VPN is on.
   A live run uses a separate `XDG_STATE_HOME` and records no PullRequest id.

Likely owners from reading the code. These are guesses, not measurements:

- Transient tree-sitter parse trees. `collectCaptureIntervals` in `src/highlight/tree_sitter_highlighter.zig` makes a parser and a tree for each File side and frees both.
  Several enrichment workers run at the same time, so the peak can hold several trees of large Files.
  A tree-sitter tree is often many times larger than its source.
- Freed malloc memory that the allocator did not return, from step 2.
- The compiled highlight queries of each grammar that the Review uses. They live as long as the Highlighter.
- The Session Diff and the Buffer of a Review with many Files.

The File cache is not a candidate for the remainder.
`retainedBytes` in `src/tui/file_enrichment.zig` counts the capacity of the arena of each File side, so the cache bytes already hold the blob and its highlights.

## Comments

2026-11-16: Triage. This ticket moves out of M28 into its own directory, with the status `ready-for-agent`.
The M28 decision "no change" does not depend on the answer, for these reasons:

- The LRU evicts by the bytes that it counts, and these bytes already hold the blob and the highlights of each File side.
  Memory outside that count cannot cause an eviction, and no cache policy can remove it.
- A full-Review memory cache would add at most 33.7 MiB, the `full_review_bytes` of PullRequest A.
  A large owner outside the cache makes that addition a smaller share of the process, so the answer cannot argue for a larger cache.
- The ADR-0016 reopen conditions use `full_review_bytes`, not the RSS.

So M28 merges without this answer.
The question still matters for a reviewer on a laptop, because 816 MiB is a large process for a terminal UI.
No measurement ran during this triage, because the reasoning above settles the M28 question and the benchmark has no offline mode.
The operator can set `wontfix` if the memory of a large Review is not a priority.
