# Error handling

## Record a failure once

[ADR-0014](../../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md) holds the rule and its reasons. In code:

- Propagate with `try` inside a module.
- When a `catch` records a failure and the function must still fail, return `diagnostic.fail(phase, cause, @src())`.
  `Handle.fail` in `src/diagnostics.zig` records the Failure and returns `error.Reported`.
  The callers above keep `try`.
- When the function has no new evidence to add, return the error and record nothing. The boundary records it once.
- Keep records out of `errdefer |err|`. An `errdefer` runs only when the function returns the error, so the layer above records the same failure again.
- At a boundary, give `error.Reported` its own prong that records nothing. Record every other error once.
  Then restore state or show the failure.
  The boundaries are worker task entry points, Presentation event and command handlers, CLI `main` through `exitFailure`, and the SQLite and HTTP seams.

`error.Reported` drops the name of the cause, and the diagnostic file is off by default.
Before you call `fail`, find the boundary above the site.
If that boundary prints `@errorName(err)` or branches on the error name:

- On a CLI path, print the message at the site first, then return `fail`.
  The leaf has the most context for the message (TigerBeetle, `vsr.fatal`).
  At a translation site, the message names the leaf cause and the translated meaning.
- On a TUI path, the site cannot print. Return the plain error without a record, and the boundary records it once.

`tools/check_diagnostics.py` counts each `catch` or `errdefer` handler that records and then returns an error.
A count in `tools/diagnostic_record_baseline.txt` can go down. It cannot go up.
