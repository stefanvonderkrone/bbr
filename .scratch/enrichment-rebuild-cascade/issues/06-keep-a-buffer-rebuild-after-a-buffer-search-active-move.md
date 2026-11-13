# 06: Keep a Buffer rebuild after a Buffer Search current occurrence move

Status: ready-for-agent
Blocked by: none

## Summary

[Ticket 04](04-keep-a-buffer-rebuild-after-a-review-search-selection-move.md) removed the Review Search selection from `DisclosureBuild`.
A selection move no longer discards a running Buffer rebuild.
The Buffer Search current occurrence still has the old form.

A live run on 2026-11-13 at commit `60d7553` confirms the cost.
After `/` and Enter, each `n` can move the DiffPane into Files that are not enriched yet, so File Enrichment rebuilds run while the user presses `n`.
An `n` inside the same File during such a rebuild discards the rebuild only because the current occurrence moved.
With `n` held down, almost no File Enrichment reaches the DiffPane until the user stops, and bbr uses 2 to 2.8 times as much CPU.

## Evidence

All paths are in `src/tui/presentation.zig`.

- `DisclosureBuild.create` copies `buffer_search.active` into `accepted_active`.
- `DisclosureBuild.buildFallible` passes `accepted_active` to `retainedSearchIndex` when it scans the rebuilt batch, and projects the ranges with that result.
- `acceptViewBuild` retries a build when `job.accepted_active != published.buffer_search.active`.
- `acceptAcceptedDisclosure` retries a `.general` build on the same mismatch.
- `acceptBufferDisclosure` compares it in `same_batch` for an `.input` build.

So the current occurrence is an input of the rebuilt batch's `active` index and of the `active` flag of its ranges.
It is not an input of the batch itself, the Buffer, the visual rows, or the File Tree.

### Measurement

The runner added temporary `[DEBUG-t06]` logs to a ReleaseFast build in a separate detached worktree.
The logs recorded the thread CPU time of each `DisclosureBuild.build`, each `traverseBufferSearchBy`, each `retryContentBuild`, and, for each `acceptViewBuild`, which checks failed.
A second binary, "keep", differed in one place.
`acceptViewBuild` did not compare `accepted_active`.
Before it published `job.rebuilt_batch`, it mapped the current occurrence with `retainedSearchIndex(published.buffer_search.accepted_batch, published.buffer_search.active, rebuilt)` and called `markActiveSearchRanges` with the result.

The run used `bbr local` on the two commits of ticket 04, a Review with 187,827 Buffer rows, at 160 × 80 with an empty state directory for each run.
The script waited until bbr was idle, typed `/return` (6,522 occurrences), pressed Enter, waited again, and pressed `n` at a fixed interval.
The process CPU covers the presses and the time until bbr is idle again.
The sides alternated.
Load average was 4.6 to 6.8 on 18 cores from other agents.

`n` every 0.1 seconds, 200 presses, about the rate of a held key:

| Side | Runs | Process CPU | Enrichment builds | Retries | Retries for the current occurrence only | Builds admitted |
| --- | --- | --- | --- | --- | --- | --- |
| Today | 5 | 23.1 to 23.6 s | 106 to 129 | 104 to 127 | 71 to 96 | 2 each |
| Keep | 3 | 8.3 to 11.2 s | 41 to 42 | 18 to 22 | 0 | 19 to 23 |

`n` every 0.5 seconds, 40 presses:

| Side | Runs | Process CPU | Enrichment builds | Retries | Retries for the current occurrence only |
| --- | --- | --- | --- | --- | --- |
| Today | 4 | 8.3 to 8.8 s | 39 to 43 | 9 to 10 | 3 to 4 |
| Keep | 2 | 7.7 to 8.0 s | 38 to 39 | 5 to 6 | 0 |

The worker build is the limiter.
The sum of the build CPU times is 92 to 95 percent of the process CPU in every run.
One enrichment build took about 170 ms of CPU time, so each discarded build costs about 0.17 s of the single worker.

With a held `n`, the cascade of ticket 01 comes back.
Each discard queues the rebuild again through `retryEnrichmentBuild`, the next `n` discards it again, and only 2 of 106 to 129 builds reach the DiffPane in about 27 seconds.
At one press every 0.5 seconds, the cost is small. About 4 builds are discarded, and the process CPU is about 8 percent higher.

The remaining retries of the keep binary fail other checks too.
`n` moved the cursor into another File, so `source_active_file`, the File Tree cursor, the File Tree scroll, and usually the enrichment revision differ.
Those retries are out of scope.

The logs showed no current occurrence mismatch in `acceptAcceptedDisclosure` or `acceptBufferDisclosure` in any run.
An `.input` build runs while the Buffer Search input is open, where `n` is text, not a traversal.
A `.general` build comes from a disclosure toggle, and a traversal that needs a disclosure removes a queued `.general` build in `queueAcceptedDisclosure`.

## What to build

A current occurrence move does not make a Buffer rebuild stale in `acceptViewBuild`.
When the accepted batch is the same and only the current occurrence differs, the admission takes the rebuild.
Before it publishes `job.rebuilt_batch`, it maps the published current occurrence to the rebuilt batch with `retainedSearchIndex` and marks the active ranges with `markActiveSearchRanges`.

The worker can stop reading the current occurrence, as in ticket 04: it projects the ranges with no active occurrence, and every admission maps and marks the current occurrence when it publishes.
That is the preferred form, because then no admission compares the current occurrence.
An `.accepted` or `.restore` build keeps the occurrence that it targets, because it opens a disclosure for that occurrence.

A rebuild whose accepted batch differs stays stale, as today.
The `source_active_file`, File Tree, and enrichment revision checks do not change.

`retainedSearchIndex` scans the rebuilt occurrences on the main thread at admission.
Today the worker runs the same scan, so the work does not grow, but it moves to the main thread.

## Acceptance criteria

- [ ] A test through `Presentation` accepts a Buffer Search, starts an `.enrichment` build, moves the current occurrence with `n` inside the same File, and completes the build.
  The Presentation admits the build, and no `build_buffer_disclosure` command waits in the queue.
- [ ] After that admission, the published current occurrence is the occurrence that was current before the admission, compared by content with `searchOccurrenceEql`.
  The published ranges mark exactly the ranges of that occurrence as active.
- [ ] A rebuild whose accepted batch changed is still rejected and retried.
- [ ] An `.accepted` build still opens the disclosure of the occurrence that it targets.
- [ ] In the live run above, with `n` every 0.1 seconds for 200 presses, each run has at most 45 enrichment builds and at most 12 s of process CPU.
  Today, the same run has 106 to 129 builds and 23.1 to 23.6 s.
- [ ] `zig build test` passes.

## Comments

### 2026-11-13, triage

Decision: `ready-for-agent`.

The live run confirms the claim for `acceptViewBuild` and `.enrichment` builds.
With `n` every 0.1 seconds, 71 to 96 of 106 to 129 enrichment builds were discarded only because the current occurrence moved, and only 2 builds were admitted in each run.
A probe binary that admitted the mismatch and mapped the current occurrence ran 41 to 42 builds and used 8.3 to 11.2 s of process CPU instead of 23.1 to 23.6 s.
With `n` every 0.5 seconds, the effect is about 4 builds and about 8 percent of the process CPU.

The runner narrowed the ticket.
The input and accepted admissions logged no current occurrence mismatch, so they change only if the worker stops reading the current occurrence.
The retries after an `n` into another File are out of scope.
The runner replaced the triage questions with a measurable target.

The probe worktrees, the logs, and the state directory are deleted.
