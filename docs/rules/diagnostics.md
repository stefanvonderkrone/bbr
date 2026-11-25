# Diagnostics rules

This document holds the checked rules for a `catch`, an error return, an error comparison, a failure record, diagnostic evidence, and a task spawn. The parts that no check covers are in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

[ADR-0014](../adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md) gives the reasons for the record-once design. [Diagnostic logging](../diagnostic-logging.md) describes the Sink, the record fields, and the evidence owners.

## A CLI failure message goes through cli_failure.fail

A CLI site that records a failure and prints its message uses `bbr.cli_failure.fail`. The helper records the cause through `fail` first and keeps its `error.Reported` result. Then it prints the message and returns that result, so a failed write cannot drop the record. When the stderr write fails, the helper records that failure once with its native cause. Then it stops output without a second flush and returns `error.Reported`.

Enforcement: `tools/check_diagnostics.py` rejects a direct `.fail` call in production `src/main.zig`, `src/completion.zig`, and `src/api/`. It also rejects one in `validateQuery` and `failTranslated` in `src/highlight/user_grammar.zig`. The `diagnostics` tests in `src/api/cli.zig` refuse stderr writes at the API boundary. `tests/record_once_cli_test.py` refuses stderr writes through the real CLI and reads exactly one original cause and one `NotOpenForWriting` record for each API, grammar, and completion failure. `zig build test` runs them.

## The record count ignores a fallback and an early return

A negative numeric fallback after a record is not an error return. An error return before a record is not a record before a return. So neither form counts against the rule in [A failure has one record](#a-failure-has-one-record).

Enforcement: `tools/check_diagnostics.py` checks only the returns after each record, and it keeps switch prongs in source order. `zig build test` runs it.

## A task wrapper receiver is the diagnostics module

A task spawn goes through `diagnostics.concurrent`, `diagnostics.selectConcurrent`, or `diagnostics.groupConcurrent` (see [A task gets its slot by pointer](#a-task-gets-its-slot-by-pointer)). The receiver of that call is the whole chain `diagnostics` or `bbr.diagnostics`. A top-level declaration in the file must make it the `diagnostics` module, in one of these forms:

- `const diagnostics = @import("diagnostics.zig")`, with any `../` prefix.
- `const diagnostics = @import("bbr").diagnostics`.
- `const bbr = @import("bbr")`.
- `const diagnostics = bbr.diagnostics`, but only beside `const bbr = @import("bbr")`.

Zig rejects a local that shadows a top-level name, so that declaration names the receiver in the whole file. A receiver such as `task_diagnostics`, a parameter named `diagnostics`, or a field `self.diagnostics` is not the wrapper. A call chain can break before each `.`.

Enforcement: `tools/check_task_spawns.py` reads the whole receiver chain before each `.concurrent(`, `.selectConcurrent(`, and `.async(` call, and the top-level declarations of the file. `zig build test` runs it.

## A merged record keeps the boundary error and the leaf cause

A record that merges leaf evidence keeps the typed error of the boundary in `boundary_error` and the leaf cause in `cause`.

Enforcement: the test "diagnostics the api boundary record holds the leaf evidence of a Bitbucket failure" in `src/api/cli.zig` checks both `MalformedResponse` and the JSON parse error. `zig build test` runs it.

## An optional Git config lookup has its own slot

An optional Git config lookup uses its own evidence slot. A fallback discards its evidence. A cancellation or an allocation failure moves its evidence to the slot of the caller and propagates.

Enforcement: the `diagnostics Git metadata fallbacks` tests in `src/git/client.zig`, run by `zig build test`.

## Paged list cleanup joins before it records

Paged list cleanup joins the workers first. Then it records each unconsumed Slot error once and frees the Slot.

Enforcement: the test "diagnostics coordinator allocation failures keep every joined page failure record" in `src/bitbucket/client.zig` checks the HTTP record count after an allocation failure. `zig build test` runs it.

## Evidence uses Context and Cause and the Sink writes it

Diagnostic evidence uses `diagnostic.Context` and `diagnostic.Cause`. Evidence holds no strings and no pointers. The process-owned `diagnostics.Sink` writes it. No code writes a failure through the standard log or the legacy Submission log.

Enforcement: the `assertSafe` checks in `src/diagnostic.zig` reject strings and pointers in context and causes. `tools/check_diagnostics.py` rejects standard-log bypasses and the legacy Submission log. `zig build test` runs them.

## A CLI error exit goes through exitFailure

A CLI error exit in `src/main.zig` calls `exitFailure` with its cause and `@src()`. `exitFailure` records every cause except `error.Reported` and exits with status 1.

Enforcement: `tools/check_diagnostics.py` rejects `std.process.exit` outside `exitFailure` in `src/main.zig`. `zig build test` runs it.

## A SQLite result goes through SqliteStore.native

A SQLite exec, prepare, step, reset, bind, or finalize result passes through `SqliteStore.native` before conversion or disposal. The wrapper can open on an earlier line and can use any receiver.

Enforcement: `tools/check_diagnostics.py` checks each result call in `src/persist/sqlite_store.zig` against its enclosing expression. `zig build test` runs it.

## A recording function takes a required Handle

A function that records diagnostics takes a required `diagnostics.Handle` parameter. No `XWithDiagnostics` function sits beside an `X` that passes a silent `.{}`. Only tests and benchmarks pass `.{}`.

Enforcement: `tools/check_diagnostics.py` rejects each production `fn` whose name ends in `WithDiagnostics`. `zig build test` runs it.

## A catch captures and records its cause

A production `catch` captures its cause (`catch |err|`) and records it through a `diagnostics.Handle` or `Presentation.reportFailure`. An expected outcome, such as a cache miss, can drop the cause. The one sanctioned drop names each dropped error in a switch prong and has no `else` prong:

```zig
catch |err| switch (err) {
    error.X => fallback,
}
```

A handler that discards the capture with `_ = err;` is a drop. An `else` prong is a drop when its handler neither records nor returns the cause.

Enforcement: `tools/check_diagnostics.py` counts the drops in each production file and fails when a count differs from `tools/diagnostic_catch_baseline.txt`. A new drop fails. A removed drop fails until the baseline goes down. `python3 tools/check_diagnostics.py --write-catch-baseline` rewrites the file. `zig build test` runs the check.

## A failure has one record

Code records each failure exactly once. Inside a module, code uses `try`. A site that records a failure and must still fail upward returns `diagnostic.fail(phase, cause, @src())`. `Handle.fail` records the Failure and returns `error.Reported`, and the callers above keep `try`.

A `catch` handler never records its cause and then returns the capture or another plain error. An `errdefer |err|` never records. [ADR-0014](../adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md) gives the reasons.

Enforcement: `tools/check_diagnostics.py` counts each production `catch` or `errdefer` handler that records and then returns an error. A record through a same-file void helper that receives the captured cause also counts. A return of nothing, a literal, `null`, a function call, `try`, or `error.Reported` does not count. A record and a return in different prongs of a `switch` on the capture do not count. The check fails when a per-file count differs from `tools/diagnostic_record_baseline.txt`. That file lists no file, so every new site fails. `python3 tools/check_diagnostics.py --write-record-baseline` rewrites it. The `diagnostics` tests in `src/diagnostics.zig` and `src/highlight_record_once_test.zig` check `Handle.fail`. `zig build test` runs them.

## A boundary records every error except error.Reported

A boundary records every error except `error.Reported` once. Then it restores state or shows the failure. These are the boundaries:

- Worker task entry points.
- Presentation event and command handlers.
- CLI `main`, through `exitFailure`.
- The SQLite seam `SqliteStore.native`.

`Handle.record` drops a Failure whose cause is `error.Reported`, so a boundary that records it writes no second record. A boundary that maps errors to user messages names `error.Reported` in its own prong.

Enforcement: `Handle.record` in `src/diagnostics.zig` drops `error.Reported` in every build. `Sink.record` is private, so no record reaches the Sink another way. `SqliteStore.native` returns an error union, so a plain SQLite error after a recorded result does not compile. The `diagnostics` tests in `src/diagnostics.zig`, `src/tui/presentation.zig`, `src/tui/presentation_runtime.zig`, `src/tui/app.zig`, `src/api/cli.zig`, `src/main.zig`, and `src/bitbucket/client.zig` read exactly one record per failure at each boundary kind. So do `tests/record_once_cli_test.py`, `tests/config_load_cli_test.py`, and `tests/store_message_cli_test.py`. `zig build test` runs them.

## A client notes leaf evidence in the boundary slot

The HTTP, Bitbucket, and Git clients are not boundaries. Their callers branch on the error name, so the clients return the typed error without a record. A client notes the evidence that only it has through `Handle.note` in the slot of the boundary. Examples are the HTTP status, the transport phase, the JSON parse error, the page, and the Git termination. `Handle.record` puts that evidence into the one record of the same error.

The boundary frame owns the slot through `Handle.withLeaf`. `main` owns the CLI slot. The `PresentationSinkContext` of each TUI worker owns the slot of that worker.

Enforcement: the `diagnostics` tests in `src/diagnostics.zig`, `src/api/cli.zig`, `src/tui/presentation_runtime.zig`, `src/bitbucket/client.zig`, `src/tui/session.zig`, `src/tui/file_enrichment.zig`, and `src/tui/app.zig` read the leaf evidence in the one record. So do the evidence checks in `tests/record_once_cli_test.py` and `tests/git_launch_cli_test.py`. `zig build test` runs them.

## A task gets its slot by pointer

A concurrent fan-out of one client gives each task its own slot by pointer. The task binds the slot with `withLeaf`. After the join, the fan-out moves the slot of the returned failure to the parent with `Handle.adopt`.

Every production task starts through `diagnostics.concurrent`, `diagnostics.selectConcurrent`, or `diagnostics.groupConcurrent`. No task argument holds a `Handle` that carries a slot.

Enforcement: `diagnostics.concurrent`, `diagnostics.selectConcurrent`, and `diagnostics.groupConcurrent` in `src/diagnostics.zig` panic in a Debug build when a task argument holds a `Handle` with a slot. The search finds it by value, in a field, an optional, an array, or a tagged union. `tools/check_task_spawns.py` rejects every other production `.concurrent(`, `.selectConcurrent(`, or `.async(` call. `zig build test` runs the check and the tests that reach each spawn.

## A Bitbucket client error return notes fresh evidence

In `src/bitbucket/client.zig`, each production error return goes through `noted(diagnostic, error.X, phase, cause)`. This applies inside a result such as `.api_error` too. It also applies to an error outside `ApiError`, such as `OutOfMemory` or `BlobSizeMismatch`. Only a testing error such as `error.TestUnexpectedResult` in a test helper needs no note.

An input check notes `.prepare`. A response with the wrong structure notes `.validate`. A bbr policy refusal on well-formed response data, such as the PullRequest Author verdict refusal, also notes `.validate`. An item decoder that can reject an item takes the `diagnostics.Handle` of the page first. Without a fresh note, a boundary record of the error takes the evidence of an earlier failure with the same name.

Enforcement: `tools/check_diagnostics.py` checks every `error.X` except `error.Test*` in each complete return expression. It ignores error patterns in switch prongs. The `diagnostics` tests in `src/bitbucket/client.zig` check the phase, the page, and the replacement of stale evidence. The test "diagnostics a refused set-verdict shows its message and has one record" in `src/api/cli.zig` checks the `.validate` note of the PullRequest Author refusal in `Client.changeReviewerVerdict`. `zig build test` runs them.

## An error comparison uses a switch

Production Zig does not compare an error with an `error.X` literal through `==` or `!=`, in either operand order. `err == error.X` compiles against `anyerror`, so the compiler accepts a name that the error set does not contain. Use a `switch` on the error that names that error in the real set. The switch has named prongs and no `else` that drops a cause. Two runtime error values can use `==` or `!=`, because neither operand adds an error name.

Enforcement: `tools/check_error_comparisons.py` rejects comparisons with error literals in either operand order, also across lines and comments. It skips `test` blocks. `zig build test` runs it.
