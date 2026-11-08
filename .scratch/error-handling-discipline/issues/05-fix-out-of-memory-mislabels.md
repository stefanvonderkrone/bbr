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
- `src/tui/presentation.zig:8485` `ScanReviewSource.create` reports out of memory for the text errors `InvalidUtf8`, `LineEnding`, `Nul`, and `TooLong`.
- `src/tui/presentation.zig:10211` `search.Query.init` in `retryStaleBufferDisclosure` reports out of memory for those same text errors.
- `src/tui/presentation.zig:10995` reports out of memory, but `retryPost` can also fail with `error.DraftNotFound` and `error.InvalidSubmissionState`.
- Nine `parseJson` call sites in `src/bitbucket/client.zig` turn `error.OutOfMemory` into `error.MalformedResponse`. Line 1667 keeps `error.OutOfMemory`.
- `src/tui/config.zig:153` returns a read failure as `error.WriteFailed`.
- `src/tui/presentation.zig:13346` returns `error.AnchorRangeDescending` as `error.MixedSides`.
- `runRaw` in `src/git/client.zig` returns a Git launch error as the command's `on_fail` name. A missing git binary then shows `NotAGitRepo`, for example `bbr local: cannot determine SourceRef: NotAGitRepo`, and the launch cause has no record. Commit `287a9cc` restored this mapping and raised the catch baseline of `src/git/client.zig` from 3 to 4, because the operator forbade a user text change in issue 06. The fix shows the real launch error, such as `FileNotFound`, and records it once at the boundary. It changes the user text, so it needs the operator's approval.

The line numbers match the checker after commit `d32d9a3`. They did not move from `ee1662a`.

## Work

1. Give each non-OOM error its own prong with the correct user-visible outcome, or record the cause through `reportFailure` or a `diagnostics.Handle`.
2. Use the checked switch form of issue 01. Add no `else` prong.
3. Lower `tools/diagnostic_catch_baseline.txt` in the same commit.

## Acceptance

- `zig build test` passes.
- No listed site reports an error that the callee did not return.
