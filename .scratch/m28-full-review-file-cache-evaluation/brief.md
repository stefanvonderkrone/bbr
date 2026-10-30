# M28 Full-Review File cache evaluation: brief

Status: ready-for-agent
Milestone: M28

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M28.
The requirements live in the M28 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Diff glossary](../../src/diff/GLOSSARY.md) and [the Presentation glossary](../../src/tui/GLOSSARY.md).
The earlier disk-cache no-go is in [M17 ticket 09](../m17-diff-blob-highlighting-completeness/issues/09-decide-persistent-file-cache.md).

## In my own words

bbr keeps inactive File content in a byte-budgeted LRU for one Session.
The default budget is 256 MiB.
When the LRU evicts a File, bbr fetches it again when the reviewer returns to it.
M21 Review Search reads every File of the Review, so a large Review can cause many refetches.

The goal is a measured decision, not a new cache.
M28 answers one question: on real large PullRequests, does the current LRU make the reviewer wait?
If it does not, the answer is "no change", and M28 ends.
If it does, M28 picks the smallest policy that removes the wait without unsafe or unbounded retention.

## Expert approach

- Raw sources: the existing File cache and File Enrichment code, the `bench-file-acquisition` benchmark, and live Bitbucket timings for real PullRequests.
- Method: measure the current LRU first, with a fixed threshold.
  Evaluate an alternative only when the baseline shows a delay above the threshold.
  This is the same evidence rule as the M17 no-go.
- Outside check: run the benchmark twice on different days and network conditions.
  The decision holds only if both runs agree.
  Record only metadata and numbers, never source content.

## Decisions

The user made these decisions on 2026-10-30.

1. **Measure first, and stop when there is no delay.**
   Step 1 measures only the current LRU.
   If no workflow shows a delay above the threshold, M28 records "no change" in an ADR and skips the alternatives.
2. **Delay threshold: a refetch adds more than 300 ms p95 to a visible action.**
   A repeat Review Search that refetches Files also counts as a delay.
3. **The disk cache stays in the comparison.**
   When the baseline shows a delay, M28 compares the LRU, a revised LRU, a full-Review memory cache, and a disk cache.
   The disk evaluation covers source-code retention, file permissions, cleanup, size limits, ReviewIdentity and commit invalidation, atomic writes, corruption recovery, format migration, and the unavailable-cache behavior.
   The baseline includes the process-restart timing, so a restart delay can trigger the disk comparison.
4. **Benchmark PullRequests: the largest of the user's own PullRequests in `pr-webapp`.**
   The agent selected them on 2026-10-30 from the 210 open and merged PullRequests that the user wrote.
   The ranking used File count, changed lines, and binary File count from each diff.
   The diffs were deleted after the ranking.

## Benchmark PullRequests

| PullRequest | State | Files | Binary Files | Changed lines | Diff size | Reason |
| --- | --- | --- | --- | --- | --- | --- |
| `pr-webapp` #14 | merged | 593 | 1 | 109,804 | 3.5 MiB | Most Files and most changed lines |
| `pr-webapp` #545 | merged | 400 | 0 | 4,270 | 0.4 MiB | Many Files with small changes |
| `pr-webapp` #1516 | open | 316 | 0 | 2,449 | 0.4 MiB | Largest open PullRequest |
| `pr-webapp` #2119 | merged | 144 | 0 | 16,189 | 0.8 MiB | Many changed lines in a mid-size File set |
| `pr-webapp` #1436 | merged | 83 | 14 | 5,704 | 0.25 MiB | Most binary Files |

## Specification changes

- Added: the 300 ms p95 threshold and the stop rule (decisions 1 and 2).
- Changed: the alternatives run only when the baseline shows a delay.
  The TODO lines for the alternatives stay, but they depend on the baseline result.
- Added: the benchmark runs twice under different conditions.
- Added: the benchmark must confirm that bbr opens a merged PullRequest with the same File Enrichment path as an open one.
  Four of the five PullRequests are merged.
- Kept: every other M28 TODO line, including the metrics list, the ADR, and the tests for a changed policy.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the research tickets in this directory.
