# 14: Keep the SideBySide change block plans after first use

Status: ready-for-agent
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

- [ ] A test compares the rows of a SideBySide build with plans and without plans. The test covers change blocks where all pairs match, where no pair matches, and where some pairs match. The rows are the same.
- [ ] A test shows that a Session in Unified that never switches to SideBySide builds no plans.
- [ ] A test shows that the second SideBySide build after a switch uses the stored plans and does not compute them again.
- [ ] A test shows that a Session replacement drops the plans.
- [ ] On the ticket 05 workload, with alternated runs in the same session, these hold:
  - A SideBySide resize and a second switch to SideBySide each cost at most 150 ms median worker CPU.
  - The first switch to SideBySide costs at most 5 % more than the baseline.
  - The Session load and a switch to Unified cost the same as the baseline, within the spread.
  - The Buffer and visual row counts are the same as the baseline.
- [ ] The completion records the memory of the plans on the workload.
- [ ] `zig build test` passes.

## Follow-up

Re-triage [ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md) after this ticket. Its target then applies only to the one-time plan build.

## Comments
