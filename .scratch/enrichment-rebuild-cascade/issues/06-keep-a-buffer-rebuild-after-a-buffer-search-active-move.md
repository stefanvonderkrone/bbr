# 06: Keep a Buffer rebuild after a Buffer Search current occurrence move

Status: resolved
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

- [x] A test through `Presentation` accepts a Buffer Search, starts an `.enrichment` build, moves the current occurrence with `n` inside the same File, and completes the build.
  The Presentation admits the build, and no `build_buffer_disclosure` command waits in the queue.
- [x] After that admission, the published current occurrence is the occurrence that was current before the admission, compared by content with `searchOccurrenceEql`.
  The published ranges mark exactly the ranges of that occurrence as active.
- [x] A rebuild whose accepted batch changed is still rejected and retried.
- [x] An `.accepted` build still opens the disclosure of the occurrence that it targets.
- [x] In the live run above, with `n` every 0.1 seconds for 200 presses, each run has at most 45 enrichment builds and at most 12 s of process CPU.
  Today, the same run has 106 to 129 builds and 23.1 to 23.6 s.
- [x] `zig build test` passes.

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

## Completion

Commits:

- `f1e7690` tui: keep a Buffer rebuild after a Buffer Search current occurrence move.
- `e4676f0` tui: name the build kinds that open a Buffer Search occurrence.
- `10dfeaa` agents: keep the Buffer Search occurrence out of a Buffer rebuild.

### Change

A `DisclosureBuild` no longer copies the Buffer Search current occurrence, and `DisclosureBuild.create` takes no occurrence.
The worker no longer maps an occurrence into the rebuilt batch.
`acceptViewBuild` maps the published current occurrence into the rebuilt batch with `retainedSearchIndex` before it frees the old batch.
So no admission compares the current occurrence, and an `n` keeps a running rebuild.
A build that opens an occurrence keeps it in `destination_active`.
`Kind.opensOccurrence` names these kinds in an exhaustive switch: `.input`, `.accepted`, `.restore`, and `.clear_input`.
A `.general` or `.open_input` admission keeps the current occurrence, so the `.general` comparison is gone too.

The admission does not call `markActiveSearchRanges`.
The DiffPane takes the active Buffer Search ranges from `buffer_search.active` (`src/tui/render.zig`), not from the range flags.
The worker projected the ranges with no active flag before this change too.

### Tests

- "Buffer Search admits an enrichment rebuild after a current occurrence move and keeps that occurrence" covers criteria 1 and 2.
  It failed before the change, because the Presentation retried the build and did not publish its visual rows.
  It also fails when the old field and the old comparison in `acceptViewBuild` come back.
  It compares the published ranges and the rendered active state with the full projection.
- "Buffer Search rejects and retries an enrichment rebuild after its accepted batch changes" covers criterion 3.
  It fails when the batch pointer check in `acceptViewBuild` is removed.
- "M21 hidden traversal publishes a complete worker Frame" covers criterion 4.

### Live run

The run used the workload of the triage: ReleaseFast, `bbr local fb701b1 1836261`, 160 × 80, an empty state directory for each run, `/return`, Enter, then `n` at a fixed interval.
The CPU is the process CPU from the first `n` until bbr is idle again.
The baseline is `4bf740d`, the result is `f1e7690`. Both had the same temporary `[DEBUG-t06]` logs in separate detached worktrees.
The sides alternated.
Load average was 1.7 to 3.5 on 18 cores.

`n` every 0.1 seconds, 200 presses:

| Side | Runs | Process CPU | Enrichment builds | Retries | Retries for the current occurrence only | Builds admitted | Final match |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Baseline | 5 | 20.61 to 20.67 s, median 20.64 s | 153 to 155 | 151 to 153 | 116 to 117 | 2 | 201/6522 |
| Result | 5 | 6.59 to 6.65 s, median 6.64 s | 44 | 19 to 21 | 0 | 23 to 25 | 201/6522 |

`n` every 0.5 seconds, 40 presses:

| Side | Runs | Process CPU | Enrichment builds | Retries | Final match |
| --- | --- | --- | --- | --- | --- |
| Baseline | 3 | 5.42 to 5.48 s | 38 | 0 | 41/6522 |
| Result | 3 | 5.45 to 5.54 s | 38 | 0 | 41/6522 |

At 0.1 seconds, the result uses 3.1 times less CPU and runs 3.5 times fewer builds.
The baseline counts are higher than in the triage, and a build is cheaper, about 0.13 s of CPU instead of about 0.17 s.
This is probably the effect of commits `f900968` and `8f69a51`, so more builds start during the presses. Nobody measured that cause.
The build count explains the CPU: about 0.13 to 0.15 s per build on both sides.
The remaining 19 to 21 retries follow an `n` into another File and are out of scope.
At 0.5 seconds, each build ends before the next press, so neither side discards a build, and the sides do not differ.
Every run ended on the expected match, so every press ran.
The logs had no line other than the debug lines.

### Checks

- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.
- `python3 tools/check_benchmark_metrics.py`: pass.
- `python3 tools/check_diagnostics.py`: pass.

### Review

A two-axis code review found no correctness problem.
The Standards review found the list of kinds that open an occurrence in three places, and commit `e4676f0` moved it into `Kind.opensOccurrence`.
It also found two sentences over 20 words in the new rules table row, and the commit split them.
The Spec review confirmed that the skipped `markActiveSearchRanges` call is correct, because the DiffPane reads the index.
It noted one older gap: a queued `.accepted` build stops without a retry when an earlier admission replaced the accepted batch.
Each admitted rebuild replaces the batch, so the gap can occur more often now.
In the live runs every press reached its match, so the runs did not show it.
[Ticket 15](15-carry-the-search-destination-in-the-build-kind.md) asks whether the build kind should carry its destination.

