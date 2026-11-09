# A failure is recorded once, and error.Reported marks it

One bbr failure often has more than one record in the diagnostic file. `runMain` records a config load failure and returns it, and `main` records the same failure again (`src/main.zig:117` and `src/main.zig:51`). An HTTP connect failure has a record from the `errdefer` in `StdHttpClient.send` (`src/http/std_client.zig:62`) and another from `Client.send` (`src/bitbucket/client.zig:118`). Each record has its own `@src()`, so a reader cannot tell one failure with two records from two failures. Code will record each failure exactly once. A site that records a failure and must still fail upward returns `error.Reported`. That error tells each layer above that the failure has its record.

## Decision

- Inside a module, code propagates an error with `try`.
- Code records each failure exactly once.
- A site that records a failure and must still fail upward returns `diagnostic.fail(phase, cause, @src())`. `Handle.fail` in `src/diagnostics.zig` records the Failure through `Handle.failure` and returns `error.Reported`, the only member of its error set `error{Reported}`. The callers above keep `try`.
- A boundary records every error except `error.Reported` once. Then it restores state or shows the failure.
- `Handle.record` in `src/diagnostics.zig`, the only way to the Sink, drops a Failure whose cause is `error.Reported`. So a boundary that records `error.Reported` writes no second record.
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

The SQLite seam is the other kind of boundary. It is `SqliteStore.native` in `src/persist/sqlite_store.zig`. It converts a SQLite result code into a typed cause. No layer above the seam sees the result code, so the seam is the one place that can record it. The seam records it once and restores its own state, for example with a `ROLLBACK`. Then the seam fails upward through `fail`, like any leaf, and the boundaries above skip `error.Reported`. No caller names a `SqliteError` member, so no caller loses a branch.

The HTTP transport in `src/http/std_client.zig`, the Bitbucket client in `src/bitbucket/client.zig`, and the Git client in `src/git/client.zig` are not boundaries. Their callers branch on the error name or print it, and they serve the CLI and the TUI, so they cannot print a message first. They return the typed error without a record, and the boundary that receives it records it once. The evidence that only they have travels beside the error in a slot that the boundary owns, as the Consequences describe. Issue 06 first planned to convert `StdHttpClient.send` to `fail`. The operator decision of 2026-11-08 replaced that plan.

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
- The check sees only `catch` and `errdefer` handlers. At this decision, `SqliteStore.native` recorded a failed result and returned the code. The caller then returned a plain `SqliteError`, and Presentation recorded that error again, as the `checkpointSubmissionRetry` handler in `src/tui/presentation.zig` did. Now `native` returns `error.Reported` through `fail`, and Presentation writes no second record. At this decision, `sqlite_store.zig` had 100 production returns of `error.Open`, `error.Exec`, `error.Prepare`, or `error.Step`. 88 of them follow a `native` check on the same line or the line before. No code outside `sqlite_store.zig` names a `SqliteError` member, so these sites can return `error.Reported`, and no caller loses a branch.
- `Handle.record` drops a Failure whose cause is `error.Reported` in every build. The review of issue 06 found two boundaries that recorded `error.Reported`: `demoRun` in `src/main.zig` and the Presentation handlers behind a store call that renames the error. The record count does not depend on the prong.
- A boundary still needs its `error.Reported` prong for the message. Without the prong, a boundary that shows the error name shows `Reported`. That is a convention with no check.
- `error.Reported` drops the name of the cause. A boundary that shows `@errorName(err)` shows `Reported`, and a boundary that branches on a name no longer sees that name. `writeError` in `src/api/cli.zig` prints the error name and branches on `error.MissingCredential` and `error.NotFound`. The Zig start code logs the name of an error that `main` returns (`std/start.zig:760-761`). The TUI shows the name of a failed File acquisition (`src/tui/render.zig`).
- The cost is larger in bbr than in the Zig compiler. The compiler records the message that the user reads. bbr records evidence in the diagnostic file, and the `[logging]` table leaves that file off by default (`src/logging_config.zig`). When the file is off, `fail` writes nothing, and the boundary that skips `error.Reported` writes nothing either. So the user has no other trace of the dropped name.
- So bbr follows TigerBeetle for the message: "the leaf of the call stack has the most context for printing error message" (`vsr.fatal` doc, `src/vsr.zig:715-730` at `68958eb7`). A `fail` site on a CLI path records through `diagnostic.fail(phase, cause, @src())` first and keeps its `error.Reported` result. Then it prints its own message to stderr and returns that result. A failed write cannot drop the record. The boundaries above print nothing more for `error.Reported`. `run` in `src/api/cli.zig` does this with `printError`.
- At a translation site, the message names what the user needs: the leaf cause and the translated meaning. So no site has to choose between losing the name and losing the leaf cause. The operator made this decision on 2026-11-08.
- A site on a TUI path cannot print, because the terminal is in raw mode. When its boundary branches on the error name, as Presentation and the File acquisition status in `src/tui/render.zig` do, the site returns the plain error without a record, and the boundary records it once.
- bbr does not adopt `vsr.fatal` or an exit status for each reason. A CLI failure still exits with status 1.
- A record names the typed error that reached the boundary. Issue 06 lost the evidence that only the leaf had: the JSON error behind `MalformedResponse`, the HTTP phase of a transport failure, the exact HTTP status of a rejection, the page number of a failed page, and the Git termination behind `UnknownRef` or `NotAGitRepo`. Issue 07 carries it to the one record.
- The evidence travels in a slot that the boundary owns. `diagnostic.Leaf` names the typed error that it explains and holds an optional phase, page, and cause. `Handle.withLeaf` points a handle at the slot, and `forContext` keeps the pointer. A client calls `Handle.note`, which writes the slot and records nothing. `Handle.record` puts the slot's evidence into the record of the same error and empties the slot. A record of another error does not take it. So a translation site on a CLI path records the client error and prints the translated meaning, as `runSetVerdict` in `src/api/pullrequests.zig` does (issue 09).
- A record takes old evidence when a client returns an error without a note after an earlier note of the same error name. Each client error return in `src/bitbucket/client.zig` goes through `noted`, which notes the phase and returns the error, and `tools/check_diagnostics.py` rejects a plain return of an `ApiError` member there (issue 09). `Handle.explain` keeps a slot whose error does not match, because a record of an unrelated error must not drop the evidence of the error that the boundary records next.
- `main` owns the CLI slot. `runPresentation` removes it from the TUI handles, and each worker owns a slot in its `PresentationSinkContext`. A slot has one writer at a time, so a concurrent fan-out gives each task its own slot: the `PagedLists` pages, the `session.loadWith` branches, the File Enrichment sides, and the Session load of a worker. A sequential call that can fail with the same error name as a later call also gets its own slot, as the Reviewer Verdict mutation does beside its reconciliation read. The fan-out moves the slot of the failure that it returns to the parent slot with `Handle.adopt`.
- Every production task starts through `diagnostics.concurrent` or `diagnostics.selectConcurrent`. They reject a `Handle` with a slot in the task arguments, by value or in a field, an optional, an array, or a tagged union, and a Debug build panics. So a task gets its slot by pointer and binds it with `withLeaf`. `tools/check_task_spawns.py` rejects any other `.concurrent(` or `.async(` call. The check does not follow a pointer, so a Handle behind a pointer or a type-erased source, such as the Client in a `BlobSource`, is not checked. `RemoteBlobSource` takes the slot of the request, not of its Client. The Git client takes the slot of its caller for `diff` and `blob`, because a File side and an Anchor transition read through one client. `std.Io` has no task identity, and an evented `Io` runs many tasks on one thread, so a check in `note` cannot tell two tasks apart.
- We rejected three other carriers. An extended `Client.ErrorDetail` reaches only the CLI and needs a merge at each boundary. A typed result union rewrites every client method and every caller. A thread-local slot hides the state and fails under an evented `Io`.
- A failed SQLite finalize repeats the error of the statement's last step. `SqliteStore.native` records the step and gives the finalize no second record.
- A site that turns a client error into an outcome without the cause records it, like a boundary. `Poster.post` does this for an ambiguous POST, `Client.changeReviewerVerdict` for each cause that its result does not name, `loadWith` in `src/tui/session.zig` for a second failed acquisition, `RemoteBlobSource` for a retried first attempt, `GitAnchorResolver` for an unavailable transition, and `PagedLists.deinit` for a failed page that the caller does not receive, on every exit of `listPagesConcurrent`. A caller that gets the reason in the result records it, as `executeReviewerVerdict` does with completion evidence.
- `Client.send` records no HTTP rejection. It recorded the status before, and the boundary recorded the typed rejection error again. It now notes the status and classification, and the boundary's one record holds them. Presentation passes `error.Reported` through its store translations, so a store failure behind `persistence_failed` keeps its one record.
