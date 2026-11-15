# 21: Find why the visual rows cost more without a candidate build

Status: ready-for-agent
Blocked by: none

## Summary

[Ticket 07](07-build-the-search-candidates-without-a-second-buffer.md) skips the candidate build and the corpus copy of a Unified resize.
The skipped phases had a median of 34.1 ms, but the whole resize lost only 22.2 ms.
In the same runs, the visual row phase of a resize went from 17.2 ms to 26.5 ms.

The triage of 2026-11-15 found two causes of this gap of about 9.8 ms:

- About 7.3 ms is the CPU clock ramp after idle. It is not work, and no code change in the visual row build recovers it.
- About 2.4 ms is a growth copy of the visual row array in the job arena, with 1,640 more page faults. A capacity reservation recovers it.

This ticket now removes the growth copy. The expected saving is about 2.5 ms of thread CPU per Unified resize, about 2 percent.
The clock ramp part is closed as inherent. See the comment of 2026-11-15.

## Cause

### The CPU clock ramp

Each action of the workload comes after 1.5 s of idle time.
The build worker starts on a core of the 12-core Performance cluster (core numbers 0 to 11), moves to a core of the 6-core Super cluster (core numbers 12 to 17) during the job, and that core then raises its clock.
A fixed ALU loop of 2 million xorshift steps, with no memory access, measured this ramp inside the job:

| Where in the job | Loop time, median |
| --- | --- |
| Job start | 6.1 ms |
| Before the visual rows, no candidate build | 4.5 ms |
| Before the visual rows, with the candidate build | 3.1 ms |
| After the visual rows | 3.2 ms |
| Back-to-back File Enrichment jobs (no idle) | 2.6 to 2.8 ms |

So the same instructions cost up to 2.3 times more at the start of a job than on a warm core.
When the candidate build ran first, it used the slow part of the ramp, and the visual rows ran on a fast core.
Without it, the visual rows run earlier in the ramp.
The cost moved from the skipped phases into the visual rows, so the saving in thread CPU time is smaller than the skipped phases.
The same effect makes the `buffer` phase 30 to 33 ms after idle and 14 ms in back-to-back File Enrichment jobs.

### The growth copy in the job arena

`frame.buildVisualRowsWithOptions` appends to an `ArrayList(VisualRow)` in the job arena with no reservation.
`std.heap.ArenaAllocator` grows the last allocation in place only to the end of its current block.
Without a candidate build before it, the array reaches the end of that block: 26 in-place remaps succeed, one fails, and the list allocates a new block and copies the array.
After a candidate build, the arena already has a large block (375 MB of capacity instead of 107 MB), and all 27 remaps succeed.
A counting allocator around the visual row allocator showed this:

| Resize | Allocations | Remaps (succeeded / failed) | Minor faults in the phase |
| --- | --- | --- | --- |
| No candidate build (`a9f04f2`) | 2 | 26 / 1 | 3,755 to 3,791 |
| Forced candidate build | 1 | 27 / 0 | 2,113 to 2,150 |
| No candidate build, reserved capacity | 1 | 1 / 0 | 2,114 to 2,150 |

## What to build

Reserve the visual row array once before the loop in `buildVisualRowsWithOptions`, so that no growth copies it.

- Reserve `rows.len + rows.len / 2` rows with `ensureTotalCapacityPrecise`. Every Buffer row makes at least one visual row. The workload needs 1.10 to 1.12 times the Buffer rows in Unified and 1.44 times in SideBySide.
- The reservation is virtual memory. Pages that no row writes are not touched and cause no fault. `toOwnedSlice` shrinks the array in place, because it is the last allocation of the block.
- A layout that needs more rows than the reservation still grows the array, as now. The reservation is a size hint, not a limit.
- The `buildUnwrappedVisualRows` path keeps its current allocation.

A sketch of this change at `a9f04f2` passed `zig build test --summary all` (exit 0, 56 of 56 steps, 1,665 of 1,665 tests).

## Rejected directions

- Set the build worker to `QOS_CLASS_USER_INTERACTIVE` so that it starts on a fast core. Measured: no change in the loop time at job start (6.2 ms) or in the visual row phase (25.0 ms). It would also cost energy.
- Run work before the visual rows to warm the core. A 35 ms spin made the visual rows 7.3 ms faster, but the job used 24.5 ms more thread CPU.
- Count the visual rows in a first pass. The wrap computation is most of the phase, so a second pass costs more than the copy.

## Method

Use the workload and method of [ticket 05](05-make-a-buffer-rebuild-faster.md) and ticket 07: `bbr local fb701b11db249ad7e57779fd1fa859085b51b946 18362616348204d57f111e15ad7f22e1a841a9e3` from a checkout of this repository, ReleaseFast, tmux at 160 × 80, a separate `XDG_STATE_HOME` with mode `700`, and one Draft with 14 paragraphs.
Put temporary `[DEBUG-21]` marks in `DisclosureBuild.buildFallible` in a detached worktree. Read the thread CPU clock, and the minor faults from `getrusage` around the visual row phase.
Alternate the baseline and the change, at least three runs per side, with 8 resizes (`tmux resize-window -x 150`, then `-x 160`) per run. Wait 1.5 s after each action.
Record the process CPU of the 8 resizes with `ps -o time=`. Report the machine load.

Phase times after idle include the clock ramp. A change that removes work early in the job moves ramp time into later phases. Compare the total of the job, and use the fault and allocation counts, which do not depend on the clock.

## Acceptance criteria

- [ ] A test builds the visual rows of a Buffer at two widths in each Layout and gets the same rows as before the change.
- [ ] On the workload, the visual row phase of a Unified resize makes one allocation and no failed remap. Its minor faults go from about 3,770 to about 2,130.
- [ ] On the workload, the median visual row phase of a Unified resize is at least 2 ms lower than the baseline of the same run. The baseline of the triage was 26.9 ms.
- [ ] The median total of a Unified resize does not grow, and no other phase grows by more than the run-to-run spread.
- [ ] A switch to SideBySide makes one allocation for its visual rows and no failed remap.
- [ ] The Buffer rows and the visual rows of each measured rebuild are the same as in the baseline.
- [ ] No `[DEBUG-21]` or `[DEBUG-t21]` line stays in the repository.
- [ ] `zig build test` passes.

## Comments

### 2026-11-15 triage

**Question.** Ticket 07 left the user goal, a large and measured cut of the CPU load of Buffer rebuilds, about 9 ms short. The visual row phase of a resize grew from 17.2 to 26.5 ms when the candidate build was skipped. This triage names the cause and the part that a change can recover.

**Probe.** Temporary `[DEBUG-t21]` marks in `DisclosureBuild.buildFallible` at `a9f04f2`, in a detached worktree that is now removed. Per phase: thread CPU (`CLOCK_THREAD_CPUTIME_ID`), wall time, and minor faults (`getrusage`). Around the visual rows: the arena capacity before and after, and a counting allocator for allocations, remaps, resizes, and frees. In diagnostic runs only: the core number (`pthread_cpu_number_np`) and a fixed 2-million-step xorshift loop at the job start, before the visual rows, and after them. Environment switches, one per variable: force the candidate build, reserve the visual row array (`rows.len + rows.len / 8`), spin for 35 ms of thread CPU before the visual rows, and set the worker QoS.

**Result.** Three runs per side, alternating A, D, R, C, CR. 8 resizes per run, so n = 24 per side. ReleaseFast on an Apple M5 Pro with 18 cores (6 Super, 12 Performance). The 1-minute load average was 0.9 to 3.1 from other work. Worker CPU per Unified resize, median [range], in ms:

| Side | Total | Visual rows | Faults in visual rows | Process CPU, 8 resizes |
| --- | --- | --- | --- | --- |
| A: `a9f04f2` | 110.0 [88.1, 111.7] | 26.9 [18.2, 31.8] | 3,773 | 0.94, 0.92, 0.91 s |
| D: forced candidate build | 134.3 [113.7, 139.6] | 17.1 [15.8, 18.1] | 2,132 | 1.12, 1.13, 1.13 s |
| C: 35 ms spin before the visual rows | 134.5 [121.3, 137.8] | 19.6 [17.7, 20.8] | 3,773 | 1.15, 1.12, 1.12 s |
| CR: spin and reservation | 132.8 [114.6, 134.8] | 17.2 [15.7, 19.5] | 2,132 | 1.11, 1.08, 1.11 s |
| R: reservation | 108.1 [84.6, 111.8] | 24.4 [16.2, 27.3] | 2,132 | 0.92, 0.87, 0.92 s |

The gap reproduces: 26.9 ms against 17.1 ms.
The spin does no memory work. It removes 7.3 ms of the gap (26.9 to 19.6 ms) and leaves the allocations and faults unchanged, so that part is the clock.
With the clock equal, the reservation removes the other 2.4 ms (19.6 to 17.2 ms, the same as D), so that part is the growth copy and its faults.
Without the spin, the reservation saves 2.5 ms in the visual rows and 1.9 ms in the total. The total saving is smaller than the run-to-run range, but the fault and allocation counts change in every resize.
The process CPU of R is 0 to 0.05 s lower per 8 resizes. That agrees with the phase saving, but it is inside the noise.
The `rest` phase (file tree and search projection) is 50.0 ms on A and 51.2 ms on R, inside its range, so the saving does not move into a later phase.
The build kinds were `view` for every resize. The Buffer rows were 187,839 on every side, and the visual rows 206,104 or 209,672 by width.

**Ruled out.**

- Page faults of fresh memory alone: a slow visual row phase (25 ms) and a fast one (18 ms) on A have the same 3,755 faults. The faults explain only the growth copy part.
- The release of the previous corpus: on a reused corpus it only drops a reference. On D it is part of the `release` phase, outside the visual rows.
- Data cache warmth from the candidate build: with the clock and the allocations equal (CR), the visual rows cost the same as on D.
- Worker QoS: `USER_INTERACTIVE` gave a job-start loop of 6.2 ms and a visual row phase of 25.0 ms, the same as the default QoS (`0x15`). This was one diagnostic run of 8 resizes with the clock loop on.

No `sample` profile was taken. The counting allocator and the clock loop separate the two causes without one.

**Decision.** `ready-for-agent` for the reservation, with the small target above. The clock ramp part, about 7.3 ms, is inherent: it is part of every job that starts after idle, and it moved from the skipped phases into the visual rows. It is not new work, so no further ticket follows it.

**Lead, not measured.** The `rest` phase of every rebuild has about 11,000 minor faults (about 170 MB at 16 KB pages). At the cost that the growth copy shows, about 1.5 µs per fault, that can be 15 ms of a 110 ms resize. A probe of `SearchProjection.create` with the same counting allocator can show whether a growth copy causes it.
