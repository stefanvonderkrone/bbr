# Error handling

## Record a failure once

[ADR-0014](../../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md) holds the rule and its reasons. In code:

- Propagate with `try` inside a module.
- When a `catch` records a failure and the function must still fail, return `diagnostic.fail(phase, cause, @src())`.
  `Handle.fail` in `src/diagnostics.zig` records the Failure and returns `error.Reported`.
  The callers above keep `try`.
- When the function has no new evidence to add, return the error and record nothing. The boundary records it once.
- When a client that the boundary branches on has evidence that the error name drops, such as an HTTP status or a Git exit code, call `Handle.note` with a `diagnostic.Leaf` for that error and return the error.
  `note` records nothing. `Handle.record` puts the evidence into the boundary's one record of the same error.
  A concurrent fan-out gives each task its own slot (`Handle.withLeaf`), because a slot has one writer at a time.
- Keep records out of `errdefer |err|`. An `errdefer` runs only when the function returns the error, so the layer above records the same failure again.
- At a boundary, give `error.Reported` its own prong that records nothing. Record every other error once.
  `Handle.record` drops `error.Reported`, so the prong keeps the name `Reported` out of the message, not out of the file.
  Then restore state or show the failure.
  The boundaries are worker task entry points, Presentation event and command handlers, CLI `main` through `exitFailure`, and the SQLite seam `SqliteStore.native`.
  The HTTP, Bitbucket, and Git clients are not boundaries. They return the typed error and record nothing.

`error.Reported` drops the name of the cause, and the diagnostic file is off by default.
Before you call `fail`, find the boundary above the site.
If that boundary prints `@errorName(err)` or branches on the error name:

- On a CLI path, record through `fail` first and keep its `error.Reported` result.
  Then print the message and return that result, so a failed write cannot drop the record.
  The leaf has the most context for the message (TigerBeetle, `vsr.fatal`).
  At a translation site, the message names the leaf cause and the translated meaning.
- On a TUI path, the site cannot print. Return the plain error without a record, and the boundary records it once.

`tools/check_diagnostics.py` counts each `catch` or `errdefer` handler that records and then returns an error.
A count in `tools/diagnostic_record_baseline.txt` can go down. It cannot go up.

## Compare errors with a switch

Do not write `err == error.X` or `err != error.X`.
That comparison compiles when `X` is not in the error set, because it widens the set to `anyerror`.
Switch on the error and name each prong.
`tools/check_error_comparisons.py` rejects the comparison in production Zig.

When the error set contains `error.Canceled`, name that prong.
Return `error.Canceled`, call `io.recancel()`, or use `unreachable` under `io.swapCancelProtection(.blocked)`.
`std.Io.sleep` and `Group.await` return only `error.Canceled`, so an `else` prong does not compile on those calls.
