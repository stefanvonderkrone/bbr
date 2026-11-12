# 01: Coalesce File Enrichment rebuilds

Status: ready-for-agent
Blocked by: none
Session: OpenCode `ses_e76b68046ffeuy22et9of1N7Dp`

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
   Its id is in `pullrequests.txt` outside the repository, in the comment line that names this ticket.
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
That rebuild carries every File Enrichment result that arrived before the worker starts it.
A result that arrives while a rebuild runs joins the queued rebuild.
When the Presentation rejects a stale enrichment rebuild, it replaces the queued rebuild with one rebuild that carries the results of both.
It does not append a second rebuild.

A batched rebuild keeps each per-File effect of the current single-File rebuild.
These effects are in `acceptFileEnrichment`, `retryEnrichmentBuild`, and the enrichment branch after the commit in `acceptViewBuild`:

- The `hold_enrichment` cache lease, for each File that Review Search does not hold yet.
- The speculative flag, for each result.
- `countFileCandidates`, the `acquired` flag, and `pumpReviewSearchAcquisition`.
- The Review Search occurrence that waits for the File, the pending review location, and the version restoration.
- On an allocation failure, `cancelReviewLocationForFile` and `resetLoading` for every File in the batch, and the error message only for a result that is not speculative.

A view rebuild, such as the one for `o`, does not wait behind more than one enrichment rebuild.

[M21 ticket 06](../../m21-buffer-review-search/issues/06-define-streaming-file-acquisition.md) coalesces query scans in the same way.
It is prior art, not a blocker.

## Acceptance criteria

- [ ] A Presentation test delivers many File Enrichment results while one enrichment rebuild runs. The queue then holds at most one enrichment rebuild, and it carries all of those results.
- [ ] A Presentation test makes the queued enrichment rebuild stale. The Presentation replaces it with one rebuild that carries every result. No result is lost, and no result is built twice after its commit.
- [ ] A Presentation test dispatches `o` while results arrive. The isolation applies after at most one enrichment rebuild.
- [ ] Tests show each per-File effect in the list above for a batch of at least two Files, including an allocation failure in a batch with a speculative and a non-speculative result.
- [ ] After all Files are enriched, the Review Search candidate count and the Buffer are the same as with single-File rebuilds.
- [ ] The live check: Review Search `e` on PullRequest A at 160 × 80 returns the CPU use to idle. The completion records the time and the number of enrichment rebuilds. Before the change, the estimate was about 2 hours and 23 rebuilds for each File.
- [ ] `zig build test` passes.

## Comments

### 2026-11-12 triage

The runner triaged the ticket at the operator's request and set it to `ready-for-agent`.
The measurements in this ticket prove the cause, and no other ticket covers it.
The triage added the per-File effects of a batched rebuild and made the acceptance criteria testable at the Presentation seam.
The live check needs a Bitbucket Credential and the VPN. An agent can run it in tmux with a separate `XDG_STATE_HOME`, as the M30 outside check did.

