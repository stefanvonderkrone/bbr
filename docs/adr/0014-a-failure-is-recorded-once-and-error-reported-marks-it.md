# A failure is recorded once, and error.Reported marks it

One bbr failure often has more than one record in the diagnostic file. `runMain` records a config load failure and returns it, and `main` records the same failure again (`src/main.zig:117` and `src/main.zig:51`). An HTTP connect failure has a record from the `errdefer` in `StdHttpClient.send` (`src/http/std_client.zig:62`) and another from `Client.send` (`src/bitbucket/client.zig:118`). Each record has its own `@src()`, so a reader cannot tell one failure with two records from two failures. Code will record each failure exactly once. A site that records a failure and must still fail upward returns `error.Reported`. That error tells each layer above that the failure has its record.

## Decision

- Inside a module, code propagates an error with `try`.
- Code records each failure exactly once.
- A site that records a failure and must still fail upward returns `diagnostic.fail(phase, cause, @src())`. `Handle.fail` in `src/diagnostics.zig` records the Failure through `Handle.failure` and returns `error.Reported`, the only member of its error set `error{Reported}`. The callers above keep `try`.
- A boundary records every error except `error.Reported` once. Then it restores state or shows the failure.
- A boundary that maps errors to user messages names `error.Reported` in its own prong.
- A `catch` handler never records its cause and then returns the capture or another plain error. An `errdefer |err|` never records, because it runs only when the function returns the error. Code records through `fail`, or it propagates the error and records nothing.

A leaf that has the cause records it and fails upward in this form:

```zig
const manifest = parseManifest(bytes) catch |err|
    return diagnostic.fail(.decode, .{ .zig = err }, @src());
```

Issue 06 gives the CLI boundary this shape, so it records only an error that has no record yet:

```zig
fn exitFailure(diagnostic: bbr.diagnostics.Handle, cause: anyerror, comptime source: std.builtin.SourceLocation) noreturn {
    switch (cause) {
        error.Reported, error.LoginAborted => {},
        else => _ = diagnostic.failure(.execute, .{ .zig = cause }, source),
    }
    std.process.exit(1);
}
```

## Boundaries in bbr

A boundary is a place where an unrecorded error gets its record.
Most boundaries cannot return an error, or they own a decision that the user sees:

- Worker task entry points, such as `presentationPrepareSessionWorker` in `src/tui/app.zig`. They return no error. They deliver a typed completion that carries its evidence.
- Presentation event and command handlers (ADR-0012). They record through `Presentation.reportFailure`. Then they keep the Published review intact and show the failure in the Projection.
- CLI `main` in `src/main.zig`, through `exitFailure`.

The SQLite and HTTP seams are the other kind of boundary. They are `SqliteStore.native` in `src/persist/sqlite_store.zig` and `StdHttpClient.send` in `src/http/std_client.zig`. A seam converts a foreign result, such as a SQLite result code or an HTTP status, into a typed cause. No layer above the seam sees the foreign result, so the seam is the one place that can record it. The seam records it once and restores its own state, for example with a `ROLLBACK`. Then the seam fails upward through `fail`, like any leaf, and the boundaries above skip `error.Reported`. Today `StdHttpClient.send` records in an `errdefer`, which this decision forbids, so issue 06 converts it.

## Why

A release build has no error return trace. The langref enables the trace by default in Debug only, and disables it in ReleaseSafe, ReleaseFast, and ReleaseSmall (`langref.html.in:3259`, research.md "Error return traces"). The `@src()` in a `diagnostic.Failure` is then the only origin in the diagnostic file. A record at the leaf names the leaf. A record at a boundary names the boundary.

Three Zig code bases put the record in three places (research.md, sections Ghostty, TigerBeetle, and Zig issue #2647):

- Ghostty records at the boundary. A `void` `threadMain` calls the `!void` `threadMain_` and logs the error (`src/renderer/Thread.zig:193-197` at `5813c946`). The log has the error name, and nothing from the leaf.
- TigerBeetle records at the leaf and stops there. The `vsr.fatal` doc says that propagating a fatal error "doesn't improve experience --- the leaf of the call stack has the most context for printing error message" (`src/vsr.zig:715-730` at `68958eb7`). bbr's TUI must recover and show the failure, so it cannot stop at the leaf.
- The Zig compiler records at the leaf and propagates a marker. In Zig issue #2647 (2024-12-10), Andrew Kelley describes `fail` helpers that record the message and return a one-error set, such as `fn fail(diags: *Diags, …) error{LinkFailure}` in `src/link.zig`. "Then error.AlreadyReported is used to indicate the error state has already been recorded somewhere and you can keep using try."

Only the third keeps the leaf context and still propagates, so bbr adopts it.

Yuan et al. ("Simple Testing Can Prevent Most Critical Failures", OSDI 2014) support the propagation half. Cassandra had the fewest bugs per handler, and "The vast majority of the exceptions are handled by recursively propagating them to the callers, and are handled by top level methods in the call graphs" (p. 261). The same paper counts "an error handler that only logs the error" as a handler that ignores the error (p. 256). So a boundary does more than record. It restores state or shows the failure.

## Options considered

### Handle or propagate

Code either propagates an error without a record or handles it at a boundary with one record. This is Ghostty's split, and it needs no new error. We rejected it because it loses the leaf cause at a translation site. `RuntimeGrammar` loading in `src/highlight/user_grammar.zig` catches the `std.DynLib.open` error and returns `error.NativeLibraryLoadFailed`. Only that `catch` sees the `DynLib` error. A boundary sees the translated name and its own `@src()`.

### Record at the leaf, and let each boundary skip by convention

Code records at the deepest point that has context, and each boundary leaves out a failure that a layer below recorded. Issue 03 first proposed this. We rejected it because a boundary cannot tell a recorded error from an unrecorded one. Both arrive as the same error name. No check can enforce a skip that has nothing to test.

## Consequences

- `tools/check_diagnostics.py` counts each production `catch` or `errdefer` handler that records through `failure`, `record`, or `reportFailure` and then returns an error. A return of nothing, a literal, `null`, a function call, `try`, or `error.Reported` does not count. In a `switch` on the capture, a record in one prong and a return in another prong do not count.
- The count for each file is in `tools/diagnostic_record_baseline.txt`. A new site fails the check, and a removed site fails until the count goes down. At this decision the file holds 51 sites in 12 files. 32 are `catch` handlers, and 19 are `errdefer` handlers.
- `exitFailure` records, but it never returns, so the check does not count it as a recording call.
- The check sees only `catch` and `errdefer` handlers. `SqliteStore.native` records a failed result and returns the code. The caller then returns a plain `SqliteError`, and Presentation records that error again, as the `checkpointSubmissionRetry` handler in `src/tui/presentation.zig` does. `sqlite_store.zig` has 100 production returns of `error.Open`, `error.Exec`, `error.Prepare`, or `error.Step`. 88 of them follow a `native` check on the same line or the line before. No code outside `sqlite_store.zig` names a `SqliteError` member, so these sites can return `error.Reported`, and no caller loses a branch.
- A boundary that skips `error.Reported` and records every other error is a convention with no check.
- `error.Reported` drops the name of the cause. A boundary that shows `@errorName(err)` shows `Reported`, and a boundary that branches on a name no longer sees that name. `writeError` in `src/api/cli.zig` prints the error name and branches on `error.MissingCredential` and `error.NotFound`. The Zig start code logs the name of an error that `main` returns (`std/start.zig:760-761`). The TUI shows the name of a failed File acquisition (`src/tui/render.zig`).
- The cost is larger in bbr than in the Zig compiler. The compiler records the message that the user reads. bbr records evidence in the diagnostic file, and the `[logging]` table leaves that file off by default (`src/logging_config.zig`). When the file is off, `fail` writes nothing, and the boundary that skips `error.Reported` writes nothing either. So the user has no other trace of the dropped name.
- So bbr follows TigerBeetle for the message: "the leaf of the call stack has the most context for printing error message" (`vsr.fatal` doc, `src/vsr.zig:715-730` at `68958eb7`). A `fail` site on a CLI path prints its own message to stderr first, and then it returns `diagnostic.fail(phase, cause, @src())`. The boundaries above print nothing more for `error.Reported`. `run` in `src/api/cli.zig` does this with `printError`.
- At a translation site, the message names what the user needs: the leaf cause and the translated meaning. So no site has to choose between losing the name and losing the leaf cause. The operator made this decision on 2026-11-08.
- A site on a TUI path cannot print, because the terminal is in raw mode. When its boundary branches on the error name, as Presentation and the File acquisition status in `src/tui/render.zig` do, the site returns the plain error without a record, and the boundary records it once.
- bbr does not adopt `vsr.fatal` or an exit status for each reason. A CLI failure still exits with status 1.
- `docs/diagnostic-logging.md` says that "The same error can appear at multiple boundaries with different context." That stays true until issue 06 converts the counted sites.
