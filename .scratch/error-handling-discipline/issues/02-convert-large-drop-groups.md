# Convert the large drop groups

Status: ready-for-agent
Type: implementation
Blocked by: 01
Parent: ../PRD.md

## Goal

Convert the large groups of cause-dropping `catch` sites to the sanctioned form of issue 01, or to a helper that holds it.
The baseline in `tools/diagnostic_catch_baseline.txt` then falls from 381 to fewer than 100 sites.
The remaining sites are the real review list.

## Groups

The counts come from research.md, section "Implications for bbr", proposal 2.

| Group | Sites | Proposed form |
| --- | --- | --- |
| `allocPrint(scratch, …) catch "label"` in `src/tui/render.zig` | 64 of 92 | One helper, for example `labelOr(scratch, fmt, args, fallback)`, that holds the one `OutOfMemory` switch. |
| `catch { self.action_error = .out_of_memory; … }` in `src/tui/presentation.zig` | 47 of 125 | The named `OutOfMemory` switch. Optionally also call `reportFailure` with `error.OutOfMemory`. |
| `catch return error.X` translations across `src/` | 91 | `catch \|err\| switch (err) { error.Overflow, error.InvalidCharacter => return error.InvalidNumber }`. |
| `bufPrint(&buf, …) catch unreachable` | 13 | `catch \|err\| switch (err) { error.NoSpaceLeft => unreachable }`, with an assertion or a comment on the buffer size. |
| `catch {}` | 21 | Review each site by hand. Keep a drop only for cleanup or best-effort output. |

## Work

1. Convert one group per commit. Lower the baseline in the same commit.
2. For each remaining site, check that the handler leaves a valid state. Yuan et al. found that empty and log-only handlers caused 25% of catastrophic failures. A record through a `diagnostics.Handle` alone does not make a drop correct.
3. List the residue in this issue under `## Comments`, with one line per site and its reason.

## Decide before resolution

- Open question 1 of the PRD: is `error.OutOfMemory` in a render path an expected outcome or a failure to record?
- Open question 2 of the PRD: does a log-only `catch` count as a drop?

## Acceptance

- `zig build test` passes after each commit.
- The baseline is below 100 sites.
- Each remaining site has a reason in this issue.
