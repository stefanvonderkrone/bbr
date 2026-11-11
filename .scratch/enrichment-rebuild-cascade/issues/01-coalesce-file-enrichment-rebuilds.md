# 01: Coalesce File Enrichment rebuilds

Status: needs-triage
Blocked by: none

## Summary

A Review Search on a large PullRequest keeps one worker at 100 percent CPU for a long time.
During that time, `o` does not isolate a File.
The live M30 outside check found it on 2026-11-11, and `main` at commit `3b29039` has the same behavior.

The cause is a rebuild cascade.
Each File Enrichment result queues a full Buffer rebuild.
Each commit of a rebuild makes every queued rebuild stale.
A stale rebuild runs in full, the Presentation rejects it, and the rebuild goes to the end of the queue again.

## Reproduction

1. Open PullRequest A, the largest benchmark PullRequest from M28, at 160 × 80.
   It has 593 Files and about 111,700 Buffer rows.
2. Open Review Search with `g f`, and type `e`.
3. Watch the CPU use of bbr. It stays at about 100 percent.
   The candidate count in the Review Search status grows slowly.
4. Close Review Search, and press `o` on a File. The isolation does not appear.

A Session whose Files are all enriched does not show the stall.

## Evidence

The runner added temporary timing logs to a `main` build and ran the reproduction for 120 seconds.

| Measure | Value |
| --- | --- |
| Enrichment rebuilds that ran | 696 |
| Enrichment rebuilds that the Presentation rejected as stale | 683 |
| Enrichment rebuilds that committed | 12 |
| Queued rebuilds during the run | about 70 |
| Rebuilds of each File before its commit | about 23 |
| Time of one rebuild | about 0.15 seconds |

A rough estimate for all 593 Files is about 2 hours of CPU time.
After `o`, the view rebuild ran 4 times in 60 seconds, and the Presentation rejected each run.

A CPU sample of the worker shows `DisclosureBuild.buildBuffer`, `buildVisualRowsWithOptions`, `buildSearchCandidates`, and `SearchProjection.create`.

## Cause

All paths are in `src/tui/presentation.zig`.

1. `acceptFileEnrichment` queues one `DisclosureBuild` of kind `.enrichment` for each completed File Enrichment.
   The build takes a snapshot of the Session inputs when the Presentation creates it.
2. Review Search acquires every File, so it starts an Enrichment for each File.
   The results arrive faster than the worker can rebuild the Buffer.
3. The Presentation runs one `build_buffer_disclosure` command at a time, in queue order.
4. When an enrichment rebuild commits, `commitCacheUpdate` increments `session.enrichment.revision`.
5. `acceptViewBuild` rejects an enrichment rebuild whose `cache_revision` differs from that revision.
   It also rejects a view rebuild whose `frame_revision` or `inputs` changed.
6. `retryContentBuild` creates a new rebuild and appends it to the end of the queue.
   So each commit wastes one full rebuild for each queued rebuild, and a view rebuild never reaches the front with current inputs.

## What to build

At most one enrichment rebuild waits in the queue.
That rebuild applies every File Enrichment result that arrived before the worker starts it.
A result that arrives while a rebuild runs goes into the next rebuild.
A view rebuild, such as the one for `o`, is not starved by enrichment results.

## Acceptance criteria

- [ ] The number of enrichment rebuilds is not larger than the number of enrichment commits plus one for each rebuild that a user action made stale.
- [ ] A test with many File Enrichment results and a slow rebuild shows that a stale rebuild is not run again for each later commit.
- [ ] `o` during a Review Search acquisition of all Files isolates the File after at most one enrichment rebuild.
- [ ] Review Search on PullRequest A acquires all Files, and the CPU use returns to idle in a time close to one rebuild for each batch of results.
- [ ] The Review Search candidate count and the Buffer content after all Files are enriched are the same as before the change.

## Comments
