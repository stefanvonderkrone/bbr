# 07: Build the search candidates without a second Buffer

Status: needs-triage
Blocked by: none

## Summary

This is win 2 of [ticket 05](05-make-a-buffer-rebuild-faster.md).
`buffer.buildSearchCandidates` builds a second full Buffer with every disclosure expanded, and then reads the source lines from it.
After ticket 05, it is the second largest phase of a rebuild.

Ticket 05 measured the median worker CPU of this phase on its fixed workload:

| Rebuild | candidates | Whole rebuild |
| --- | --- | --- |
| Resize, Unified | 39 ms | 163 ms |
| Layout switch to Unified | 39 ms | 167 ms |
| Layout switch to SideBySide | 139 ms | 372 ms |

A disclosure toggle does not build candidates, so it gets nothing from this ticket.

## Directions

- Reuse the candidates of the previous rebuild when their inputs did not change. A resize and a Layout switch to the same Layout change no candidate input except the card width.
- Read the source lines without the row weave. A candidate needs the Line text and its identity, not the visual layout of the Buffer.

## Method

Use the workload and the measurement method of ticket 05: `bbr local` on the two fixed commits, ReleaseFast, tmux at 160 × 80, one long Draft, temporary `[DEBUG-t07]` timing marks in `DisclosureBuild.buildFallible` in a separate detached worktree, and alternating baseline and changed runs.

## Acceptance criteria

- [ ] The candidates of each rebuild kind are the same as before: the same count, order, and text.
- [ ] The candidates phase of a SideBySide Layout switch costs at least 50 percent less worker CPU than the baseline of the same run.
- [ ] `zig build test` passes.
