# Record each failure once through fail

Status: claimed
Claimed by: /Volumes/Work/t3-code/error-handling-discipline (branch feat/record-once)
Type: implementation
Blocked by: 03
Parent: ../PRD.md

## Goal

Each failure has one record in the diagnostic file.
Convert each site that `tools/diagnostic_record_baseline.txt` counts.
A converted site records through `Handle.fail`, or it returns the error and records nothing.
Teach each boundary to record nothing for `error.Reported` and to record every other error once.
[ADR-0014](../../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md) holds the rule and its costs.

## Sites that the check counts

At commit `427fdb9`, `tools/check_diagnostics.py` counts 51 sites in 12 files.
The line numbers are from that commit.

| File | Sites | `catch` | `errdefer` | Lines |
| --- | --- | --- | --- | --- |
| `src/api/cli.zig` | 3 | 3 | 0 | 314, 321, 339 |
| `src/bitbucket/client.zig` | 14 | 2 | 12 | 23, 118, 579, 1093, 1169, 1274, 1380, 1488, 1590, 1669, 1903, 1993, 2261, 2667 |
| `src/completion.zig` | 1 | 0 | 1 | 46 |
| `src/git/client.zig` | 1 | 1 | 0 | 159 |
| `src/highlight/grammar_cli.zig` | 3 | 3 | 0 | 118, 122, 259 |
| `src/highlight/tree_sitter_highlighter.zig` | 1 | 1 | 0 | 54 |
| `src/highlight/user_grammar.zig` | 10 | 10 | 0 | 279, 296, 377, 488, 504, 526, 531, 540, 545, 763 |
| `src/http/std_client.zig` | 2 | 0 | 2 | 38, 62 |
| `src/main.zig` | 10 | 6 | 4 | 51, 117, 196, 208, 340, 351, 356, 621, 635, 1285 |
| `src/tui/app.zig` | 1 | 1 | 0 | 1151 |
| `src/tui/file_enrichment.zig` | 4 | 4 | 0 | 36, 309, 319, 338 |
| `src/tui/session.zig` | 1 | 1 | 0 | 98 |

Notes on some sites:

- `src/main.zig:51` is `main`. It is the CLI boundary, so it ends through `exitFailure` instead of a record and a return.
- `src/api/cli.zig:314` and `321` show the message through `printError` before they return. They can return through `fail` after `printError`.
- `src/highlight/user_grammar.zig:279` and `377` translate the `std.DynLib.open` error to `error.NativeLibraryLoadFailed`. The CLI shows that name, because the Zig start code logs the name of an error that `main` returns.
- `src/api/cli.zig:339` translates `error.MissingUsername`, `error.MissingToken`, and `error.MissingWorkspace` to `error.MissingCredential`, and `writeError` branches on that name. This is a translation site whose new name a boundary uses.
- The operator decided the translation sites on 2026-11-08, after TigerBeetle: the leaf has the most context for the message. A CLI-path site prints a message that names the leaf cause and the translated meaning, and then it returns `fail`. A TUI-path site whose boundary branches on the name returns the plain error without a record. ADR-0014 holds the rule.
- `src/highlight/tree_sitter_highlighter.zig:54` records twice in one handler. It records the Zig error and then the predicate diagnostic.
- `enrichSide` in `src/tui/file_enrichment.zig` has the error set `error{OutOfMemory}`. Its handlers at 319 and 338 record the error and return it when it is `error.OutOfMemory`. `error.Reported` in that set changes each caller's switch.

## Sites outside the check

`SqliteStore.native` records a failed SQLite result and returns the code.
The caller then returns a plain `SqliteError`, and Presentation records that error again.
`src/persist/sqlite_store.zig` has 100 production returns of `error.Open`, `error.Exec`, `error.Prepare`, or `error.Step`.
88 of them follow a `native` check on the same line or the line before.
No code outside `sqlite_store.zig` names a `SqliteError` member.
Return `error.Reported` after a recorded result.
When the store converts, consider a check for a `native` check before a plain `SqliteError` return, and add its count to `tools/diagnostic_record_baseline.txt`.

## Work

1. Teach each boundary to record nothing for `error.Reported`:
   - `exitFailure` and `main` in `src/main.zig`.
   - `Presentation.reportFailure` in `src/tui/presentation.zig`.
   - Each worker entry point that turns an error into completion evidence, such as the workers in `src/tui/app.zig` and `src/tui/presentation_runtime.zig`.
   - Each CLI subcommand boundary that prints an error, such as `writeError` in `src/api/cli.zig`.
2. Before you convert a site, find the boundary above it.
   If that boundary prints `@errorName(err)` or branches on the error name, a CLI-path site prints its message first and returns `fail`, and a TUI-path site returns the error without a record.
   Otherwise return `diagnostic.fail(phase, cause, @src())`.
3. Convert the `errdefer |err|` records to a `catch` with `fail` on the call that has the evidence, or remove them.
4. Convert the SQLite sites outside the check.
5. Lower each count with `python3 tools/check_diagnostics.py --write-record-baseline` in the same commit as the conversion.
6. Update the sentence "The same error can appear at multiple boundaries with different context." in `docs/diagnostic-logging.md`.

## Acceptance

- `tools/diagnostic_record_baseline.txt` lists no file.
- For each boundary kind in step 1, a test records one failure from a leaf `fail` and finds exactly one record.
- Each CLI failure that printed a name before this issue still prints a message for that failure. A `*_cli_test.py` check proves it for the config load failure of `runMain`.
- `zig build test` passes.
- `python3 tools/check_agent_docs.py` passes.
