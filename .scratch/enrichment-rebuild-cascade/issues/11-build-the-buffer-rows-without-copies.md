# 11: Build the Buffer rows without copies

Status: ready-for-agent
Blocked by: none

## Summary

The triage of tickets 07 to 09 on 2026-11-13 found the largest remaining cost of a Unified Buffer rebuild.
About 28 % of the CPU samples of a Unified rebuild are `memcpy` of the Buffer row array.
Both Buffer builds of a rebuild pay this cost: the Buffer itself and the second Buffer of the search candidates.

## Evidence

All paths are in `src/tui/buffer.zig`.

- `buildWithComments` appends each Row to `rows` through `opts.scratch_allocator`.
  `BuildOptions.scratch_allocator` defaults to `std.heap.page_allocator`.
- On macOS, each growth of that array on the page allocator copies the whole array.
- At the end, `buildWithComments` copies the rows once more with `allocator.dupe(Row, rows.items)`.

The runner measured worker CPU per rebuild at commit `60d7553` on the workload of [ticket 05](05-make-a-buffer-rebuild-faster.md).
The runs alternated with a prototype.
The load average was 2.7 to 6.8 on 18 cores.
The prototype reserved the row array once in the build arena and dropped the final copy.

| Rebuild | Baseline median | Prototype median | Change |
| --- | --- | --- | --- |
| Resize, Unified | 172 ms | 126 ms | −27 % |
| Toggle, Unified | 120 ms | 102 ms | −15 % |
| Switch to SideBySide | 401 ms | 351 ms | −12 % |

The prototype kept the Buffer and visual row counts unchanged.

## What to build

A Buffer build grows its row array without a copy of the whole array on each growth, and returns the rows without a final copy.
For example, the build reserves the row array once from a count or an upper bound, in the allocator that owns the result.
The Buffer keeps the same rows in the same order.

## Acceptance criteria

- [ ] A test shows that a Buffer build returns the same rows in the same order as before, for Unified and SideBySide, with Comments, Drafts, folds, and disclosures.
- [ ] No `dupe` of the row array remains at the end of `buildWithComments`.
- [ ] On the ticket 05 workload, the median worker CPU of a Unified resize is at least 20 % lower than a baseline from the same session, with alternated runs.
- [ ] The Buffer and visual row counts are the same as the baseline.
- [ ] `zig build test` passes.

## Comments

### 2026-11-13 filed

Filed from the triage report of tickets 07 to 09. Tickets 07 and 08 state their targets relative to a baseline of the same run, so they hold in any order with this ticket.
