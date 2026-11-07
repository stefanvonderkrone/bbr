# Fix the out-of-memory mislabels

Status: needs-triage
Type: implementation
Blocked by: 02
Parent: ../PRD.md

## Goal

Some handlers report an error as out of memory, or as another wrong error, when the callee can also fail for a different reason.
The user then sees the wrong message, and the diagnostic loses the real cause.
The codemod of issue 02 found these sites and left them unconverted.

## Sites

- `src/tui/presentation.zig:7064` reports out of memory, but `createPersisted` can also fail with `error.DraftNotFound`.
- `src/tui/presentation.zig:8485` and `src/tui/presentation.zig:10211` report out of memory for the text errors `InvalidUtf8`, `LineEnding`, `Nul`, and `TooLong`.
- `src/tui/presentation.zig:10995` reports out of memory, but `retryPost` can also fail with `error.DraftNotFound` and `error.InvalidSubmissionState`.
- Nine `parseJson` call sites in `src/bitbucket/client.zig` turn `error.OutOfMemory` into `error.MalformedResponse`. Line 1667 keeps `error.OutOfMemory`.
- `src/tui/config.zig:153` returns a read failure as `error.WriteFailed`.
- `src/tui/presentation.zig:13346` returns `error.AnchorRangeDescending` as `error.MixedSides`.

The line numbers refer to commit `ee1662a`.

## Work

1. Give each non-OOM error its own prong with the correct user-visible outcome, or record the cause through `reportFailure` or a `diagnostics.Handle`.
2. Use the checked switch form of issue 01. Add no `else` prong.
3. Lower `tools/diagnostic_catch_baseline.txt` in the same commit.

## Acceptance

- `zig build test` passes.
- No listed site reports an error that the callee did not return.
