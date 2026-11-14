# 14: Keep the SideBySide change block plans after first use

Status: resolved
Blocked by: none

## Summary

[Ticket 13](13-find-why-a-switch-to-side-by-side-costs-three-times-more.md) found that each SideBySide rebuild matches the removed and added Lines of every change block, and does it twice: once for the Buffer and once for the search candidate Buffer.
The match result depends only on the Diff, so it does not need to change between rebuilds.
A prototype that kept the match plans in the Session cut a switch to SideBySide from 331.5 ms to 144.7 ms of worker CPU, and a SideBySide resize from 332.6 ms to 139.9 ms.

The user decided on 2026-11-13 that the plans are built on the first SideBySide use, not at Session load.
A user who never opens SideBySide must not pay the plan build, which costs about 100 ms of CPU on the workload of [ticket 05](05-make-a-buffer-rebuild-faster.md).

## Design constraints

- The Session is read-only on the worker. A worker must not write the plans into a shared Session.
- One possible shape: the first SideBySide build computes the plans as part of its result. The Presentation admission moves the plans into the Session-owned store on the Presentation thread. Later builds read the plans from the Session.
  The implementer can choose another shape when it keeps one owner of the plans and no worker writes shared state.
- A build that starts before the plans exist computes the plans itself, as today. It never waits for another build.
- The plans belong to one Session. A Session replacement or a Refresh drops them with the Session.
- When the preferred Layout is SideBySide at Session load, the first build is the first use.
- Both Buffer builds of a rebuild use the same plans. When no plans exist yet, the build computes them once and uses them for both Buffer builds.
- The plans also cover the change blocks above `side_by_side_work_limit`, which use the index pairing today. This is proposal 2 of ticket 13. Leave it out when it makes the change much larger, and record that in the completion.

## Acceptance criteria

- [x] A test compares the rows of a SideBySide build with plans and without plans. The test covers change blocks where all pairs match, where no pair matches, and where some pairs match. The rows are the same.
- [x] A test shows that a Session in Unified that never switches to SideBySide builds no plans.
- [x] A test shows that the second SideBySide build after a switch uses the stored plans and does not compute them again.
- [x] A test shows that a Session replacement drops the plans.
- [x] On the ticket 05 workload, with alternated runs in the same session, these hold:
  - A SideBySide resize and a second switch to SideBySide each cost at most 150 ms median worker CPU.
  - The first switch to SideBySide costs at most 5 % more than the baseline.
  - The Session load and a switch to Unified cost the same as the baseline, within the spread.
  - The Buffer and visual row counts are the same as the baseline.
- [x] The completion records the memory of the plans on the workload.
- [x] `zig build test` passes.

## Follow-up

Re-triage [ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md) after this ticket. Its target then applies only to the one-time plan build.

## Comments

## Completion

Commit `8f69a51` keeps the SideBySide change block plans in the Session after the first SideBySide build.

### Change

- `SideBySidePlans` in `src/tui/buffer.zig` holds the steps of each change block (a pair with the emphasis of both Lines, a left row, or a right row), keyed by the first removed Line of the block. It owns its arena and does not change after `build` returns. `complete` is true when the plans cover every File of the Diff.
- `planChangeBlock` holds both the matching path and the index pairing above `side_by_side_work_limit`, so the plans also cover the large blocks (proposal 2 of ticket 13). `emitChangeSteps` replaces the old matched emission and `emitIndexedChangeBlock`. `changeBlockAt` splits the blocks for both the plan build and the Weave, so the plan key and the lookup cannot drift apart.
- A block without a plan plans itself in the Buffer arena, as before. A block without added Lines needs no plan.
- `DisclosureBuild.create` copies `Session.side_by_side_plans` into the job on the Presentation thread. A worker reads only that copy.
- `DisclosureBuild.buildFallible` builds the plans once when the Layout is SideBySide and the job has none, and passes the same plans to each Buffer build and to `buildSearchCandidates`. An `OutOfMemory` in the plan build leaves the blocks to plan themselves.
- `DisclosureBuild.keepPlans` is the first statement of `acceptBufferDisclosure`. It moves complete plans into the Session that the job retains, when that Session has no plans yet. So an admitted, retried, stale, or discarded build of the same Session keeps its plans, and a second first build frees its plans in `destroy`. A result that arrives after a Session replacement or a Refresh can reach only the replaced Session, which the job still retains, so no identity check is necessary. The move allocates nothing.
- `Published.finishCreate` builds the plans for the initial Frame when the preferred Layout is SideBySide. It writes the field of the candidate Session on the worker. This is the one exception to the rule that only the Presentation thread writes the field. No other thread can see the candidate Session before publication, and `emphasis_cache` uses the same exception.
- The synchronous builds on the Presentation thread read the Session field and build no plans.
- `Session.destroy` frees the plans.

A SideBySide build of one isolated File builds plans for that File only. It uses them for both of its Buffers and then frees them, because they are not complete. So an isolated-File SideBySide rebuild still matches the blocks of its File once. A Session that only uses isolated Files never keeps plans.

### Tests

- buffer.zig: "side_by_side rows with stored change block plans equal rows that plan each block" covers blocks where all pairs, no pair, and some pairs match, a removed-only block, an indexed block above the work limit, and a Thread on a paired Line. It runs over `whole_file`, `fold_context`, `only_file`, both Selected Versions, and with and without blobs.
- buffer.zig: "side_by_side plans of one File leave the other Files to plan their own blocks" covers a plan lookup miss.
- presentation.zig: "a Unified Session that never switches to SideBySide builds no change block plans", "the first SideBySide build keeps its change block plans for later SideBySide builds of the Session", "a discarded first SideBySide build keeps its plans and a second first build frees its own", "a SideBySide build of one isolated File keeps no change block plans", "a SideBySide build that completes after a Session replacement keeps its plans out of the new Session", and "a Session replacement drops the change block plans of the replaced Session".
- All tests use `std.testing.allocator`.

### Measurement

The method is the method of ticket 05, with `[DEBUG-t14]` marks in detached worktrees at `c7c40c0` (baseline) and `c7c40c0` with this change (result), built with ReleaseFast. The worktrees are removed.
Each run loaded the Session, then did a first switch to SideBySide, a switch to Unified, a second switch to SideBySide, 8 SideBySide resizes (150 and 160 columns), 4 more pairs of switches, and a last switch to Unified.
Five baseline runs and six result runs alternated in the same tmux session. The 1-minute load average was 0.8 to 2.0 on 18 cores, with one spike to 9.6 at the end of the last runs.
Each action made exactly one `view` build. The parser found no errors. The two `enrichment` builds after each load are excluded.

Worker CPU, median (range), in ms:

| Rebuild | n base / result | Baseline | Result | Change |
| --- | --- | --- | --- | --- |
| First switch to SideBySide | 5 / 6 | 348.6 (340.9 to 356.5) | 221.3 (217.8 to 225.6) | −37 % |
| Later switch to SideBySide | 25 / 30 | 346.8 (337.3 to 374.9) | 127.8 (110.8 to 131.9) | −63 % |
| SideBySide resize | 40 / 48 | 336.0 (327.8 to 423.0) | 117.5 (110.1 to 123.3) | −65 % |
| Switch to Unified | 30 / 36 | 122.7 (113.6 to 160.5) | 121.8 (105.4 to 126.9) | none |
| Session load, initial Frame | 5 / 6 | 109.4 (107.7 to 110.9) | 107.6 (106.5 to 108.5) | none |

The process CPU after the load was 760 ms (740 to 780) on both sides.
The Buffer and visual rows were the same on both sides: 187,839 and 206,104 for Unified, 183,464 and 264,856 for SideBySide, and 183,464 and 278,298 at 150 columns.

The plan build costs 108.2 to 112.3 ms in the first switch. That is the matching that the baseline ran twice in each SideBySide rebuild.
A later SideBySide rebuild now spends 51 ms in the search projection, 25 ms in the candidates, 17 to 24 ms in the Buffer, 18 ms in the visual rows, and 5 ms in the corpus. No matching runs. It is lower than the 144.7 ms of the ticket 13 prototype because the plans also cover the 108 blocks above the work limit.

The plans use 2,851,642 bytes of arena capacity on the workload, in each run.

The final commit adds the `OutOfMemory` fallback and `changeBlockAt` after the alternated runs. One more pair of runs with the final code gave a first switch of 229.0 ms (plan build 117.0 ms), a later switch of 128.2 ms, a resize of 117.5 ms, and a Unified switch of 124.3 ms, against 348.8, 348.5, 337.7, and 124.1 ms for the baseline of the same pair.

### Checks

- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: exit 0.
- `python3 tools/check_benchmark_metrics.py`: exit 0.
- `python3 tools/check_diagnostics.py`: exit 0.

### Review

The two-axis code review found no hard violation of a documented standard.
It found three points that this change fixes. The plan build repeated the block split of the Weave, so `changeBlockAt` now does the split for both. A plan build `OutOfMemory` failed the build, so it now falls back. No test sent a SideBySide result after a Refresh, so a test now does.
These points stay open:

- `SideBySidePlans.build` uses the backing allocator of the Session arena. That allocator is `page_allocator` in production and lets the tests find leaks.
- The terms "change block" and "plan" are not in `src/tui/GLOSSARY.md`.
- An isolated-File SideBySide build keeps no plans, as described above.

[Ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md) has a dated note: its target now applies only to the one-time plan build and to isolated-File SideBySide builds.
