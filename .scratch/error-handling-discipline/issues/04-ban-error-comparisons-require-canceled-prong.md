# Ban error comparisons and require a Canceled prong

Status: ready-for-agent
Type: implementation
Blocked by: 01
Parent: ../PRD.md

## Goal

Two checks keep the compiler able to see each error name.

1. No production code compares an error with `==` or `!=`.
   `err == error.X` compiles against `anyerror` and silently widens the error set.
   The compiler then cannot say that the name is impossible.
   TigerBeetle bans this pattern in `src/tidy.zig` (0.17.0, `ac790315`).
2. A `catch` switch on an error set that contains `error.Canceled` names `error.Canceled` in its own prong.
   The standard library says that ignoring `error.Canceled` "is usually a bug" (`std/Io.zig:1181-1188`).
   The prong returns the error, calls `io.recancel()`, or sits under `io.swapCancelProtection(.blocked)` and writes `unreachable`.

## Known sites

- `src/tui/presentation.zig:1325`: `if (err == error.OutOfMemory) .out_of_memory else .buffer_build_failed`.

## Work

1. Add the `== error.` and `!= error.` ban as a line check in `tools/`. It reads Zig source through `zig_files` in `tools/source_lines.py` with `literals=False`. Skip `test` blocks.
2. Convert each existing comparison to a `switch` on the error.
3. For the Canceled prong, find which callee error sets contain `error.Canceled`. A regex cannot see error sets. Decide between a list of known cancelable calls and a review convention. Record the decision in this issue.
4. Add regression tests and rows to the `AGENTS.md` rule table.

## Acceptance

- `zig build test` passes.
- The old line at `src/tui/presentation.zig:1325` fails the new check.
- The rule table names each check, or marks the Canceled rule "Convention (no check)" with its reason.
