# 13: Find why a switch to SideBySide costs three times more

Type: research
Status: resolved
Blocked by: none

## Question

Why does a rebuild after a switch to SideBySide cost about three times more worker CPU than a rebuild after a switch to Unified, and which changes would close most of the gap?

## Context

[Ticket 11](11-build-the-buffer-rows-without-copies.md) measured these medians at commit `f900968` on the workload of [ticket 05](05-make-a-buffer-rebuild-faster.md):

| Rebuild | Worker CPU, median |
| --- | --- |
| Switch to Unified | 109 ms |
| Switch to SideBySide | 322 ms |

Tickets 05 and 11 cut the Unified rebuild by about 68 %, but the SideBySide rebuild by only about 44 %.
The SideBySide rebuild now costs about 213 ms more than the Unified rebuild.

The known parts of the gap:

- The SideBySide change block matching is about 55 % of a SideBySide switch, according to the triage of [ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md).
- A SideBySide rebuild runs the matching twice: once for the Buffer and once for the search candidate Buffer of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

Nobody measured the rest of the gap at the current commit.
The other phases, such as the visual rows for line pairs, the search projection, and the corpus, have no SideBySide measurement of their own.

## What to find

1. A phase breakdown of the worker CPU for a switch to SideBySide and a switch to Unified at the current commit, with a CPU profile of the rebuild worker. Report the medians, the spread, and the machine load.
2. The share of the gap for each phase, and the share that tickets 07 and 08 remove according to their prototypes or a new measurement.
3. Whether a Layout switch must rebuild everything it rebuilds today. For example, the matching result does not depend on the Layout geometry, so a later switch or a resize could reuse it.
4. A ranked list of changes with an estimated saving for each. Each estimate is labeled as measured with a prototype, or as a guess.

## Deliverable

A dated `## Comments` entry in this ticket with the evidence, the ranked list, and a proposed target for a switch to SideBySide.
Proposed child tickets go in the text of the comment. Tickets 07 and 08 get a note when the findings change their scope or target.

## Comments

### 2026-11-13 findings

**Answer.** Almost all of the gap is the change block matching, and a SideBySide rebuild pays it on every rebuild, not only on a Layout switch.
The matching depends only on the Diff, so the Session can keep its result.
A prototype that keeps it in the Session cut a switch to SideBySide from 331.5 ms to 144.7 ms of worker CPU, and the gap to Unified from 215 ms to 30 ms.

#### Method

The workload and phases are those of [ticket 05](05-make-a-buffer-rebuild-faster.md), with temporary `[DEBUG-t13]` marks in `DisclosureBuild.buildFallible` and in the change block code, in two detached worktrees at `34f6045`.
The worktrees were removed afterwards.

- `base`: `34f6045` with the marks and counters only.
- `cache`: `base` plus the Session plan cache prototype that this comment describes below.

Each run started the binary, waited for the Session load and the File Enrichment rebuilds, and then did 8 Unified disclosure toggles, 8 Unified resizes, 16 Layout switches, 8 SideBySide resizes, and 2 more switches.
A resize is one `tmux resize-window` to 150 or back to 160 columns.
The runs alternated `base` and `cache`, four times each.
The 1-minute load average was 2.4 to 3.7 on 18 cores.
Wall time and thread CPU time agree within 0.5 ms, so each rebuild is CPU-bound on one worker core.
Each action made exactly one build of the expected kind: `general` for a toggle and `view` for a resize and a switch.
A SideBySide disclosure toggle was not measured, because Enter on the rows that toggle the Draft card in Unified did not toggle it in SideBySide, and the script did not find the row.

#### Phases at `34f6045`

Worker CPU per rebuild, median (range), and the phase medians in ms:

| Rebuild | n | Median (range) | buffer | candidates | corpus | visual | tree | projection |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Switch to Unified | 36 | 116.2 (96.0 to 128.6) | 24.8 | 23.6 | 5.9 | 15.2 | 0.2 | 47.3 |
| Switch to SideBySide | 36 | 331.5 (316.8 to 351.1) | 135.0 | 122.3 | 5.2 | 18.0 | 0.2 | 51.2 |
| Resize, Unified | 32 | 116.0 (99.9 to 125.9) | 23.1 | 24.2 | 5.9 | 15.3 | 0.2 | 47.4 |
| Resize, SideBySide | 32 | 332.6 (323.0 to 344.6) | 135.2 | 122.0 | 5.2 | 18.1 | 0.2 | 50.9 |
| Disclosure toggle, Unified | 32 | 95.0 (85.6 to 102.7) | 23.4 | none | none | 22.1 | 0.2 | 49.8 |

The medians are 3 to 7 ms higher than at the completion of [ticket 11](11-build-the-buffer-rows-without-copies.md), which measured 109 ms and 322 ms. The marks and counters cost some of that.
Buffer rows and visual rows: 187,839 and 206,104 for Unified, 209,672 visual rows at 150 columns, and 183,464 and 264,856 for SideBySide, 278,298 visual rows at 150 columns.

A SideBySide resize costs the same as a switch to SideBySide: 332.6 ms against 331.5 ms.
So the cost belongs to every SideBySide rebuild, not to the Layout switch.
A File Enrichment result, a Draft save, and a resize in SideBySide each pay it.

#### Share of the gap

The gap between the two switch medians is 215.3 ms:

| Phase | SideBySide minus Unified | Share |
| --- | --- | --- |
| buffer | 110.2 ms | 51 % |
| candidates | 98.7 ms | 46 % |
| projection | 3.9 ms | 2 % |
| visual | 2.8 ms | 1 % |
| corpus | −0.7 ms | 0 % |

The two Buffer builds hold 97 % of the gap.
The visual rows of the line pairs (264,856 against 206,104 rows) and the search projection add only about 7 ms.

#### Counts

Each SideBySide Buffer build, and the second Buffer of the candidates, works through 2,458 change blocks.
108 of them are above `side_by_side_work_limit` and take `emitIndexedChangeBlock`.
The other 2,350 score 91,040 pairs of a removed and an added Line, and fill the common subsequence table of `matchingSimilarity` for 88,164 of them.
Only 2,744 pairs match, which is 3 % of the scored pairs.
So nearly all of the table work proves that a pair does not match.

#### Profile

`sample` ran for 25 seconds during 60 SideBySide resizes of `base`, in a run that the tables do not use.
`atos -i` named the inlined frames.
Of the 13,038 samples under `buildFallible`:

| Part | Share |
| --- | --- |
| `emitSideBySideHunk`, the whole subtree | 73.1 % |
| of it: `commonTable` and `tokEql` in `matchingSimilarity`, own time | 48.7 % |
| of it: `intraline.diff` of the matched pairs | 7.9 % |
| of it: `emitIndexedChangeBlock` | 3.6 % |
| `mmap` and `munmap`, all under `emitSideBySideHunk` | 8.5 % |
| `SearchProjection.create` | 16.3 % |
| `buildVisualRowsWithOptions` | 5.6 % |
| `BufferSearchCorpus.create` | 1.1 % |

The `mmap` share overlaps the parts above it: it comes from the two arenas of each change block and the arena of each `intraline.diff` call.
`buildWithComments` and `buildSearchCandidates` have almost equal shares, 37.2 % and 38.8 %, because both weave the same SideBySide hunks.

#### Must a Layout switch rebuild everything?

No.
The change block plan, which is the pair order and the emphasis segments of each matched pair, depends only on the Lines of the hunk.
It does not depend on the Layout geometry, the cell metrics, the disclosures, the Drafts, or the Threads.
The Unified Buffer already uses the same idea: `EmphasisCache` keeps the Unified hunk emphasis in the Session, and `Session.prepareEmphasis` builds it during the Session load, before the Session is published.

The rest must stay per rebuild or needs more memory:

- The visual rows and the search projection depend on the geometry and the Layout.
- The candidate corpus depends on the Layout. A corpus kept for each Layout would save the candidates and corpus phases on a switch back. [Ticket 07](07-build-the-search-candidates-without-a-second-buffer.md) rejected this for its memory cost.

**Prototype.** `cache` moves the planning part of `emitSideBySideChangeBlock` into a function that returns the steps (pair, left, right) and the segments of each pair.
`SideBySidePlans.build` runs it for each change block of the Diff in `Session.prepareEmphasis`, keyed by the first removed Line, and puts the result in the Session arena.
`emitSideBySideChangeBlock` walks a stored plan and plans the block itself only when no plan exists.
The blocks above the work limit keep `emitIndexedChangeBlock`.
The candidate build gets the same plans, so the matching runs zero times per rebuild instead of twice.

| Rebuild | n | `base` | `cache` | Change |
| --- | --- | --- | --- | --- |
| Switch to SideBySide | 36 | 331.5 ms (316.8 to 351.1) | 144.7 ms (126.8 to 151.9) | −186.8 ms, −56 % |
| Resize, SideBySide | 32 | 332.6 ms (323.0 to 344.6) | 139.9 ms (127.7 to 153.3) | −192.7 ms, −58 % |
| Switch to Unified | 36 | 116.2 ms | 115.1 ms (104.3 to 135.2) | none |

With `cache`, a switch to SideBySide has buffer 37.3, candidates 31.3, corpus 5.2, visual 17.6, and projection 52.2 ms.
Each build of `cache` hit 2,350 plans and planned only the 108 indexed blocks.
The Buffer rows and visual rows were the same as in `base`.
The full `zig build test` of `cache` finished, and the tail of its output showed no failed step. The row equality comes from the counts and from the plan code, which is the old code moved, not from a row dump.

The plans cost 96.9 to 110.0 ms of CPU once per Session load, in four loads.
`EmphasisCache.build` costs 27.7 to 50.2 ms in the same loads.
Nobody measured the memory of the plans. The guess is a few MB: one step per Line of a change block, and the segments of 2,744 pairs.

The remaining gap to Unified is 29.6 ms: buffer 13.7, candidates 7.9, projection 4.9, and visual 2.4 ms.
The 108 indexed blocks run `intraline.diff` for each index pair in both builds. The profile puts them at 3.6 % of a `base` rebuild, about 12 ms, which is most of the buffer and candidates rest.

#### What tickets 07 and 08 remove

- [Ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md): its bound prototype at `60d7553` cut a switch to SideBySide by 84.6 ms, 42 ms in each Buffer build. That is about 40 % of the gap (measured at an earlier commit with the same phase sizes). That prototype also held two steps of ticket 09, which did not lower the SideBySide projection phase. Its steps 1 and 3 have no prototype. The `mmap` share above says that step 3 can save up to about 28 ms per rebuild (guess). Without a cache, ticket 08 keeps the matching on every SideBySide rebuild.
- [Ticket 07](07-build-the-search-candidates-without-a-second-buffer.md): a switch changes its key, so it saves nothing on a switch. On a SideBySide resize it saves the candidates and corpus phases: about 127 ms at `34f6045`, or about 36 ms after the plan cache (measured phases of the two binaries; the reuse itself has no prototype).

#### Ranked changes

| Rank | Change | Saving on a switch to SideBySide | Label |
| --- | --- | --- | --- |
| 1 | Keep the change block plans in the Session, shared by the Buffer and the candidate build | −187 ms per SideBySide rebuild, also a resize. It adds about 100 ms once per Session load | measured, prototype |
| 2 | Plan the indexed change blocks once too, in the same store | about −12 ms per SideBySide rebuild | guess, from the profile |
| 3 | Ticket 08, made cheaper: the bound and one scratch arena | after rank 1, it only shortens the one-time plan build, about −40 to −60 ms per Session load. Without rank 1, −85 ms per rebuild | guess after rank 1; measured at `60d7553` without it |
| 4 | Ticket 07, the corpus reuse | none on a switch; about −36 ms on a SideBySide resize after rank 1 | guess from measured phases |
| 5 | Ticket 09, the projection | −5 to −7 ms for each measured step, in both Layouts | measured in ticket 09 |
| 6 | A corpus for each Layout | about −36 ms on a switch back, at the cost of a second corpus in memory | guess |

#### Proposed target

A switch to SideBySide and a SideBySide resize each cost at most 150 ms median worker CPU on this workload, and at most 1.35 times the switch to Unified of the same run.
The prototype gave 144.7 ms and 1.26 times.
The extra cost of the Session load stays at most 110 ms of CPU, until ticket 08 or a lazy build lowers it.

#### Proposed child tickets

These are proposals only. Nobody filed them.

1. **Keep the SideBySide change block plans in the Session.** Store the pair steps and segments of each change block next to `EmphasisCache`, built by `Session.prepareEmphasis`, and use them in both Buffer builds. Decide between a build at each Session load (simple, about 100 ms for each user, also for a user who never opens SideBySide) and a build that only starts when the preferred Layout is SideBySide, with a later build at the first switch. A test compares the rows of a build with plans and without plans for blocks that match all, no, and some pairs. Target as above.
2. **Plan the indexed change blocks once.** Store the index-pair emphasis of the blocks above `side_by_side_work_limit` in the same store. This can be part of ticket 1.
3. **Re-triage ticket 08** after ticket 1. Its target then applies to the one-time plan build, not to every rebuild.

No `map.md` exists for this feature, so this ticket adds no Decisions-so-far pointer.
