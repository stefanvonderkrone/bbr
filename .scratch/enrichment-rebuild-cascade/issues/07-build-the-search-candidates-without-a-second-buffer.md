# 07: Build the search candidates without a second Buffer

Status: ready-for-human
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

- [x] A test builds the candidates of one Session with two different card widths, two different cell metrics, and two different sets of expanded disclosures, and gets the same count, order, text, mappings, and locations.
- [x] A test builds the candidates of a Changes-scope Session with and without File blobs and gets the same candidates. In the whole-file scope, a blob change changes the key.
- [x] A test shows that a Draft add, delete, body change, and re-anchor each change the key, and that the next build makes new candidates.
- [x] After a resize, Buffer Search finds the same matches in the same order as before the resize, with an accepted query and with a typed query.
- [x] On the workload, the median of the candidates and corpus phases of a Unified resize is at most 1 ms. The baseline of the same run is about 50 ms.
- [ ] On the workload, the median worker CPU of a Unified resize is at least 25 percent lower than the baseline of the same run.
- [x] The phases of a Layout switch and a disclosure toggle do not change by more than the run-to-run spread.
- [x] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [x] No `[DEBUG-07]` or `[DEBUG-t07]` line stays in the repository.
- [x] `zig build test` passes.

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

## Completion

The change is complete, but one acceptance criterion is not met. The worker CPU of a Unified resize is 16.7 percent lower, not 25 percent. See the measurement. A human decides whether the ticket resolves with this result or waits for [ticket 21](21-find-why-the-visual-rows-cost-more-without-a-candidate-build.md).

### Change

- `e1f9659` adds Presentation tests that change one candidate input at a time and check the accepted Buffer Search matches: the Layout (pair order), the Selected Version in the whole-file scope, the scope (only the whole-file scope reads File blobs), a File blob eviction, the isolated File, a Draft add, delete, body change, and re-anchor, and a Refresh with a changed Comment. Two more tests check that a resize keeps the accepted and the typed matches, and that the candidates do not depend on the width, the cell metrics, or the expanded disclosures.
- `1009d8f` adds `SearchCandidateInputs`, `SearchCandidateScope`, and `SearchCandidateKey` to `src/tui/buffer.zig`. `buildSearchCandidates` reads only that struct. The width, the cell metrics, the highlights, the content statuses, the folds, and the expanded disclosures of the user are no longer inputs, because no candidate reads them. The Selected Version and the File blobs are in the whole-file arm of the scope, the only scope that reads them. `key` switches exhaustively over the fields of the struct, so a new input does not compile until it says how the key covers it. `BufferSearchCorpus` stores its key. `DisclosureBuild.create` retains the published corpus, and `BufferSearchCorpus.reuseOrBuild` returns it when the keys are equal. The build releases that reference before its visual rows, so a missed reuse keeps no second corpus. `Kind.buildsSearchCorpus` replaces two copies of the list of corpus kinds.
- `97c2473` adds a unit test of the key for the Session epoch, a Draft parent, a Draft state, a blob eviction, and the scope, and updates `src/tui/IMPLEMENTATION.md` and the Buffer Search entry of `src/tui/GLOSSARY.md`.

### Key coverage

| Input | How the key covers it |
| --- | --- |
| Diff, Threads, mention names | Pointer and length, and the Session epoch. A published Session never changes them, and each Session publication takes a new epoch. |
| Session epoch, Layout, isolated File | Value. |
| Drafts, scope projections | Content of every field, with the presence of each optional and the length of each slice. A Draft add, delete, re-anchor, body, parent, or state change changes the key. |
| Scope | `hunks` for the Changes and fetched scopes, which differ only in folds. `whole_file` holds the Selected Version and the identity (presence, pointer, length) of each File blob side. A side holds the same text whenever it is loaded. |
| Emphasis cache, change block plans | Not in the key. They make the build faster and leave its candidates the same. |

A key that left out one input made a test fail. A temporary edit removed each part of the key in turn and ran `zig build test`:

| Removed from the key | Failing tests |
| --- | --- |
| Layout | "a Layout switch builds the Buffer Search candidates in the order of the new Layout" |
| isolated File | "an isolated File keeps only its own Buffer Search candidates" and two older isolation tests |
| Drafts | "each Draft change changes the Buffer Search candidates" |
| Selected Version | "a Selected Version switch in the whole-file scope builds the Buffer Search candidates of that version" |
| File blob identity | "a File blob eviction in the whole-file scope removes its text from the Buffer Search candidates", the Selected Version test, and two older whole-file tests |
| scope tag alone | none, because the whole-file arm hashes more fields than `hunks` |

The Session epoch, a Draft parent, and a Draft state are covered by the key unit test of `97c2473`. The reuse test "a resize, a Changes-scope File Enrichment, and the fetched scope reuse the Buffer Search corpus" checks the identity of the published corpus. Before `1009d8f` every build made a new corpus while the old one was still published, so the identity always changed.

### Measurement

The workload and method are the ones of ticket 05 and this ticket: `bbr local fb701b1 1836261` from this checkout, ReleaseFast, tmux at 160 × 80, a separate `XDG_STATE_HOME` with mode `700`, one Draft with 14 paragraphs.
Temporary `[DEBUG-07]` marks in `DisclosureBuild.buildFallible` read the thread CPU clock in detached worktrees at `c0acc46` (baseline) and `1009d8f` (result). The worktrees are removed.
One warmup baseline run was discarded. Then three baseline runs and three result runs alternated. Each run did 8 disclosure toggles, 8 resizes (150 and 160 columns), and 8 Layout switches.
The machine has 18 cores. The 1-minute load average was 1.9 to 3.6 from other work.
Wall time and thread CPU time agree within 1.5 ms, except one baseline resize that waited 21.6 ms.

Target, written before the runs: the candidates and corpus phases of a Unified resize go from about 30 ms to under 1 ms, the whole resize drops by that amount, and the toggle and the Layout switches do not change.

Worker CPU per rebuild, median (range), in ms:

| Rebuild | n per side | Baseline | Result | candidates + corpus |
| --- | --- | --- | --- | --- |
| Disclosure toggle | 24 | 109.8 (90.8 to 116.9) | 109.9 (88.7 to 115.8) | none → none |
| Resize, Unified | 24 | 132.9 (108.3 to 138.9) | 110.7 (88.1 to 113.9) | 34.1 → 0.00 |
| Switch to SideBySide | 12 | 140.7 (138.4 to 219.1) | 140.9 (110.7 to 227.4) | 34.1 → 33.0 |
| Switch to Unified | 12 | 134.3 (126.2 to 140.7) | 135.1 (118.3 to 140.9) | 35.9 → 35.7 |

Every result resize reused the corpus (24 of 24), and no Layout switch did, because the Layout is in the key.
The resize lost 22.2 ms (−16.7 %), less than the 34.1 ms of the skipped phases. In the same resizes the visual row phase went from 17.2 to 26.5 ms. A toggle, which never builds candidates, has a visual row phase of 26.3 and 26.9 ms on the two sides. So the visual row build costs about 9 ms more when no candidate build runs before it in the job. The cause is not profiled. [Ticket 21](21-find-why-the-visual-rows-cost-more-without-a-candidate-build.md) holds it.
The 25 percent criterion was set against `60d7553`, where the two phases were 29 percent of a resize. After tickets 11 and 14 they are 26 percent of the baseline resize, so the criterion was only reachable if no other phase grew.

Process CPU for 8 actions (`ps -o time=`), three runs each:

| Action | Baseline | Result |
| --- | --- | --- |
| Disclosure toggle | 0.93, 0.91, 0.91 s | 0.94, 0.91, 0.90 s |
| Resize | 1.10, 1.14, 1.13 s | 0.94, 0.90, 0.92 s |
| Layout switch | 1.25, 1.25, 1.26 s | 1.26, 1.26, 1.22 s |

Buffer rows and visual rows were the same on both sides: 187,839 and 206,104 for Unified, 187,856 and 206,121 with the Draft expanded, 209,672 visual rows at 150 columns, and 183,464 and 264,856 for SideBySide.
Only the expected build kinds ran: `general` for a toggle and `view` for a resize and a Layout switch.

### Mistake class

The candidate class is a cached derived value whose key or invalidation misses an input, so a stale value is published with no error.
The history has one real case: `e6ab685` fixed a disclosure input snapshot that kept a Draft state after another path changed it. `8df6955` added tests for the Overview Index stale marks because no test failed when a mark was removed, but no stale value shipped.
The other caches are keyed on inputs that cannot change inside a Session: the change block plans of ticket 14 and the emphasis cache depend only on the Diff.
One real case does not make a class, so this ticket adds no rule. The new key is enforced at the type level: its exhaustive switch over the fields of `SearchCandidateInputs` fails to compile for a new input, and the build reads nothing outside that struct.

### Checks

- `zig build test --summary all`: exit 0, 56 of 56 steps, 1,665 of 1,665 tests.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`, `check_benchmark_metrics.py`, `check_diagnostics.py`, `check_search_index.py`, `check_navigation_fields.py`: pass.
- No `[DEBUG-07]` or `[DEBUG-t07]` line in the repository.

### Review

A design check before the change found two problems that the change avoids: a job that kept the previous corpus until its own destruction would keep two corpora in memory, and a hash without slice lengths and optional presence could give two inputs the same key.
The two-axis code review found no hard violation and no wrong behavior. `97c2473` fixes its findings: the missing key test for the epoch, parent, and state, the import of `MentionNames`, the key comment about digest collisions, and the stale owner line in `IMPLEMENTATION.md`.
Open judgment calls: the two `searchCandidateInputs` builders read different owners and stay separate, and the Diff, Threads, and mention names rely on the rule that a published Session never changes them, which no check enforces.

### Follow-up tickets

- [21](21-find-why-the-visual-rows-cost-more-without-a-candidate-build.md): find why the visual rows cost more without a candidate build.
- [22](22-find-each-card-search-owner-without-a-scan-of-all-candidates.md): find each card search owner without a scan of all candidates.
