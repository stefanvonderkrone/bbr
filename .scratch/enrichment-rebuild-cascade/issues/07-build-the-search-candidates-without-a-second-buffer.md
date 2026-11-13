# 07: Build the search candidates without a second Buffer

Status: ready-for-agent
Blocked by: none

## Summary

This is win 2 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
`buffer.buildSearchCandidates` builds a second full Buffer with every disclosure expanded and no folds, and then reads the source Lines and the ReviewBody text from it.
Each `.view`, `.enrichment`, `.cache_update`, `.draft_save`, `.draft_mutation`, `.review_destination`, and `.card_destination` build runs it, and then copies the result into a new `BufferSearchCorpus`.

The candidates depend on the Layout, the scope, the Selected Version, the isolated File, the Drafts, the scope projections, the Threads, and, in the whole-file scope only, the File blobs.
They do not depend on the geometry, the cell metrics, the highlights, or the expanded disclosures of the user, because the candidate build expands every disclosure itself.
So a resize builds the same candidates again, and so does a File Enrichment result in the Changes scope.

This ticket reuses the previous corpus when its inputs did not change.

## Baseline at `60d7553`

The triage measured the workload and method of ticket 05 with `[DEBUG-t07]` marks. The full evidence is in the comment below.

| Rebuild | n | Whole rebuild, median (range) | candidates | corpus |
| --- | --- | --- | --- | --- |
| Resize, Unified | 24 | 172.2 ms (152.5 to 236.7) | 45.1 ms | 5.3 ms |
| Layout switch to Unified | 12 | 174.6 ms (164.8 to 185.0) | 45.5 ms | 5.2 ms |
| Layout switch to SideBySide | 12 | 400.9 ms (380.8 to 430.6) | 151.9 ms | 5.3 ms |

The candidates and corpus phases are 29 percent of a Unified resize and 39 percent of a SideBySide switch.
A `sample` profile of Unified resizes puts 85 percent of the candidates samples in the second `buildWithComments`, and 54 percent in `memcpy` from the growth and the copy of its row array.
In SideBySide, 90 percent of the candidates samples are the change block matching of [ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md).

Two prototypes that are not part of this ticket make the second build cheaper but do not remove it:

- A row array that is reserved once in the build arena and not copied at the end: the candidates phase of a Unified resize goes from 45.1 to 26.6 ms. The runner gets this finding as a separate proposal.
- The bound of ticket 08: the candidates phase of a SideBySide switch goes from 125.6 to 83.2 ms.

After both, the candidates and corpus phases are still about 31 ms of a 120 ms Unified resize.

## What to build

Reuse the corpus of the previous rebuild when the candidate inputs are equal.

- The Presentation thread gives the build job the published `BufferSearchCorpus` with a retained reference, and the key of the inputs that built it.
- The key holds the Layout, the scope, the Selected Version, the isolated File, the Session epoch, and an identity of the Drafts and scope projections that changes when a Draft is added, deleted, re-anchored, or changes its body, parent, or state. In the whole-file scope only, it also holds an identity of the File blobs.
- If the key of the new build is equal, the build skips `buildSearchCandidates` and `BufferSearchCorpus.create` and publishes the retained corpus. The Buffer Search scans of the build run on that corpus as before.
- Otherwise the build makes the candidates as it does now.

A Layout switch changes the key, so it builds the candidates. A disclosure toggle builds no candidates now, and does not change.

## Rejected directions

- Read the source Lines without the row weave. The candidate order follows the visual order of the woven Buffer: Drafts and Comments between Lines, and in SideBySide the pair order of the change block matching. A second walk would copy all that order logic, and a difference would change the order of search results.
- Keep one corpus per Layout so that a switch back to a Layout reuses it. This saves the most on a SideBySide switch, but it keeps a second corpus of about the size of the Diff text in memory. Measure it again after ticket 08 and the row array change, if the switch is still too slow.

## Method

Use the workload and the method of ticket 05: `bbr local fb701b11db249ad7e57779fd1fa859085b51b946 18362616348204d57f111e15ad7f22e1a841a9e3` from a checkout of this repository, ReleaseFast, tmux at 160 × 80, a separate `XDG_STATE_HOME` with mode `700`, and one Draft with 14 paragraphs.
Put temporary `[DEBUG-07]` timing marks in `DisclosureBuild.buildFallible` in separate detached worktrees, and remove them before the commit.
Run the baseline binary and the changed binary in alternation, at least three times each, with 8 actions of each kind per run: a disclosure toggle, a resize (`tmux resize-window -x 150`, then `-x 160`), and a Layout switch (`s`).
Report the machine load.

## Acceptance criteria

- [ ] A test builds the candidates of one Session with two different card widths, two different cell metrics, and two different sets of expanded disclosures, and gets the same count, order, text, mappings, and locations.
- [ ] A test builds the candidates of a Changes-scope Session with and without File blobs and gets the same candidates. In the whole-file scope, a blob change changes the key.
- [ ] A test shows that a Draft add, delete, body change, and re-anchor each change the key, and that the next build makes new candidates.
- [ ] After a resize, Buffer Search finds the same matches in the same order as before the resize, with an accepted query and with a typed query.
- [ ] On the workload, the median of the candidates and corpus phases of a Unified resize is at most 1 ms. The baseline of the same run is about 50 ms.
- [ ] On the workload, the median worker CPU of a Unified resize is at least 25 percent lower than the baseline of the same run.
- [ ] The phases of a Layout switch and a disclosure toggle do not change by more than the run-to-run spread.
- [ ] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [ ] No `[DEBUG-07]` or `[DEBUG-t07]` line stays in the repository.
- [ ] `zig build test` passes.

## Comments

### 2026-11-13 triage

The runner asked for a triage of tickets 07, 08, and 09 together, and set this ticket to `ready-for-agent`.

**Measurement.** The triage put `[DEBUG-t07]` marks in `DisclosureBuild.buildFallible` at `60d7553` in separate detached worktrees, with the phases of ticket 05.
It ran three binaries in the order baseline, row prototype, full prototype, three times, with 8 actions of each kind per run.
The full prototype holds the row array change, the bound of ticket 08, and the first two steps of ticket 09.
Wall time and thread CPU time agree within 1 ms, so each rebuild is CPU-bound on one worker core.
The machine has 18 cores. Other agents gave it a load average of 2.7 to 6.8 during the runs, which explains why the baseline is 3 to 8 percent higher than at the completion of ticket 05.
Process CPU for 8 actions at the baseline: disclosure toggle 0.97, 1.04, 1.12 s, resize 1.50, 1.45, 1.52 s, Layout switch 2.34, 2.38, 2.44 s.

Worker CPU per rebuild, medians in ms, with the phases:

| Rebuild | Side | n | Median (range) | buffer | candidates | corpus | visual | projection |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Disclosure toggle | baseline | 24 | 119.9 (104.1 to 140.1) | 47.8 | none | none | 18.7 | 53.1 |
| | rows | 24 | 101.7 (79.5 to 112.1) | 27.6 | none | none | 20.6 | 53.6 |
| | full | 24 | 98.6 (74.6 to 106.4) | 27.9 | none | none | 20.9 | 48.8 |
| Resize, Unified | baseline | 24 | 172.2 (152.5 to 236.7) | 51.9 | 45.1 | 5.3 | 15.8 | 53.4 |
| | rows | 24 | 126.3 (108.2 to 142.2) | 26.5 | 26.6 | 6.3 | 15.4 | 50.4 |
| | full | 24 | 119.8 (105.1 to 130.2) | 24.7 | 25.2 | 6.2 | 15.3 | 46.1 |
| Switch to Unified | baseline | 12 | 174.6 (164.8 to 185.0) | 56.4 | 45.5 | 5.2 | 15.2 | 50.7 |
| | rows | 12 | 128.3 (111.8 to 132.8) | 29.5 | 27.5 | 6.2 | 15.1 | 49.9 |
| | full | 12 | 124.0 (98.4 to 129.6) | 26.3 | 26.2 | 6.2 | 15.5 | 46.5 |
| Switch to SideBySide | baseline | 12 | 400.9 (380.8 to 430.6) | 168.0 | 151.9 | 5.3 | 19.9 | 55.8 |
| | rows | 12 | 350.6 (338.6 to 362.8) | 144.5 | 125.6 | 5.3 | 18.5 | 54.7 |
| | full | 12 | 266.0 (246.1 to 282.4) | 102.9 | 83.2 | 5.4 | 18.6 | 57.3 |

The tree phase is 0.2 ms on every side.
The Buffer rows and the visual rows were the same on every side: 187,839 and 206,104 for Unified, 187,856 and 206,121 with the Draft expanded, 209,672 visual rows at 150 columns, and 183,464 and 264,856 for SideBySide.

**Profile.** `sample` ran during 40 seconds of Unified resizes and of SideBySide resizes at `60d7553`, in runs that the table does not use.
In the Unified profile, 1,338 of the 4,200 samples under `buildFallible` are `memcpy`. `atos` maps 833 of them to the growth of the row array in `Weave.emitUnifiedHunk` (`ArrayList.append` on the page allocator, which on macOS cannot grow in place and copies), and 358 to the copy of the rows at the end of `buildWithComments` (`allocator.dupe(Row, rows.items)`).
Both Buffer builds of a rebuild pay this. The row prototype reserves the array once in the build arena and returns it without the copy. It is outside tickets 07 to 09, so the runner gets it as a separate proposal.

**Direction.** The reuse needs no new state outside the published corpus, which already has a reference count. A prototype of the reuse was not built. The saving on a hit is the candidates and corpus phases in the table, which the reuse skips completely.

**Dependencies.** This ticket does not need ticket 08 or the row array change. A Layout switch changes the key, so ticket 08 still saves its matching twice on a switch. Measure against a baseline of the same run, so that the targets stay valid in any order.

### 2026-11-13 note from ticket 13

[Ticket 13](13-find-why-a-switch-to-side-by-side-costs-three-times-more.md) found that the matching is about 100 ms of the SideBySide candidates phase, and that a SideBySide resize costs as much as a switch.
With the change block plans kept in the Session, the candidates and corpus phases of a SideBySide rebuild fall from about 127 ms to about 36 ms.
So the saving of this ticket on a SideBySide resize shrinks to about 36 ms. The Unified targets of this ticket do not change.
