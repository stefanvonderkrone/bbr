# Diagnostic logging

## Controls and storage

Diagnostic logging is off by default. The startup setting is in `config.toml`.

```toml
[logging]
enabled = true
```

The startup reader checks this setting before command dispatch, including `api`, `auth`, `grammar`, and `completion`.
A missing setting, an invalid logging setting, or an unreadable configuration leaves startup logging off.
The reader accepts only a regular file. It opens the path without blocking and checks the type of the opened file, so a FIFO cannot block startup.
When the setting enables logging but the sink cannot open its file, bbr prints `bbr: diagnostic logging unavailable` and the cause to stderr. The command continues with the same exit status.
Commands that do not need TUI configuration still ignore unrelated TUI values.
The TUI retains its full configuration validation.

The `Toggle diagnostic logging` Action in the `ctrl-p` Command Palette changes only the current process.
The terminal adapter opens the file before Presentation reports that logging is enabled.
A failed enable leaves logging unavailable. A file write failure closes the file and makes logging unavailable.
Disabling waits for a current write to finish. Later writes do nothing.
A write blocks cancellation of its worker, so a cancelled worker cannot make logging unavailable.
The TUI status shows the logging state as its own meta item. The item does not hide an operation status or a key hint.
The Action never writes `config.toml`.

Files live in `<state home>/bbr/diagnostics`.
The state home uses an absolute `XDG_STATE_HOME`, or `$HOME/.local/state` as its fallback.
The diagnostic directory has mode `0700`. The files have mode `0600`.
The sink refuses a diagnostic directory with group or other access. It also refuses a symbolic link for that directory.
Each enable creates an exclusive file with random run and file identities.
Concurrent processes do not append to one file.
Disabling and re-enabling keeps the run identity but creates a new file.

There is no automatic file rotation, size limit, or cleanup.
Existing files remain after disablement or exit.
The application does not read or delete the old `bbr-submit-response.log` file.
That unconditional Submission log no longer receives writes.

## Records and privacy

Each file starts with a version and a random run identity.
Each subsequent record occupies one line.
The fields are space-separated `name=value` pairs.

| Field | Meaning |
| --- | --- |
| `v` | The record format version. |
| `time_ns` | The wall-clock time in nanoseconds. |
| `run` | The process run identity. It is not a Repository identity. |
| `seq` | The record sequence within the run. |
| `operation` | The code-defined operation category. |
| `phase` | The phase where the failure occurred. |
| `source` | The compiler-authored source file, line, and column. |
| `cause` | A Zig error, HTTP rejection, SQLite result, or Grammar failure. |

Available numeric context follows the source field.
It can include the command ID, work ID, Session Epoch, OperationId, Draft ID, File index, File side, attempt, or page.
Absent context fields do not appear.
Native cause fields retain HTTP classification and status, or SQLite primary and extended codes.
A Grammar cause names its `rule`: `query` with the Tree-sitter query error code, `regex` with the regex engine code, or a predicate rule such as `unknown_operator` with code 0. Each Grammar cause has the byte offset in the query, but never the query text.
Zig causes use the original error name where capture precedes domain conversion.

The sink accepts no arbitrary message or field map.
Context and cause types accept only numbers, closed enums, and Zig errors.
Records exclude Credentials, headers, raw URLs, argv, environment values, user paths, Repository names, Ref names, SQL values, and bodies.
Compiler-authored source locations identify bbr implementation files, not reviewed Files.
The sink does not capture stdout or stderr.
The existing human-facing Grammar validation report can still print query details to stderr.
That report is not copied into diagnostic files.

## Owners and checks

`src/main.zig` owns the process sink and destroys it after clients and TUI workers finish.
External adapters borrow `diagnostics.Handle` values.
A handle keeps the sink reference while logging is off, so later enablement affects existing clients.
`src/diagnostic.zig` defines the pure values that Presentation can use without file I/O.

| Boundary | Evidence owner |
| --- | --- |
| Startup and CLI failures | `src/main.zig`, `src/api/cli.zig`, and `src/completion.zig`. |
| HTTP rejection | `src/bitbucket/client.zig`. |
| Ambiguous POST transport failure | `src/bitbucket/poster.zig`. |
| SQLite result conversion | `src/persist/sqlite_store.zig`. |
| Worker launch, completion, and delivery | `src/tui/app.zig` and `src/tui/presentation_runtime.zig`. |
| Pure Action failures | `src/tui/presentation.zig`. |
| External Edit and clipboard | `src/tui/presentation_adapter.zig`. |
| File Enrichment and Highlighting | `src/tui/file_enrichment.zig`, `src/tui/code_highlighting.zig`, and `src/highlight/`. |

`zig build test-diagnostics` runs the focused diagnostic tests and source checks.
`zig build test-cli` runs the hermetic CLI checks.
`zig build test` includes the full suite, CLI checks, source checks, and formatting.
`python3 tests/diagnostic_logging_ci_test.py` checks the real TUI with private Git, config, and state directories.
It requires tmux. CI runs this check with the other `*_ci_test.py` scripts.
`python3 tools/diagnostic_inventory.py .` lists source error boundaries for an audit.
The inventory identifies source sites. It does not prove that every site has a diagnostic owner.

`tools/check_diagnostics.py` rejects standard-log bypasses.
It also rejects the legacy Submission log and unwrapped SQLite result calls.
CLI error exits in `src/main.zig` go through `exitFailure`, which requires the cause and source location.
Required failure payloads prevent payloadless Picker and recovery failures.
The launch-failure conversion requires the real launch error.
These checks target known mistake classes. They do not prove whole-program error coverage.

## Limits

Logging starts when the sink is enabled. It does not replay earlier failures.
Crashes, signals, and process termination can occur before application code captures an error.
A file write can fail after a partial line. The sink closes that file and stops further writes.
The sink does not recursively log its own failure.
Each failure has one record ([ADR-0014](adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md)).
A site that records a failure and still fails returns `error.Reported`, and the boundaries above write nothing more for it.
The Bitbucket client, the HTTP transport, and the Git client record nothing, because their callers branch on the error name.
The boundary that receives such an error records it, so its record names the typed error, not the transport phase, the JSON error, the page number, or the Git exit code.
An HTTP rejection is the exception: `Client.send` records the status, and the boundary records the typed rejection error again.

Normal cancellation, no matches, optional missing files, Submission lock contention, unsupported Grammars, and configured size limits are not operational errors.
SQLite busy and locked results remain diagnostic evidence when they prevent a store operation.
A recorded remote transport failure does not prove that a remote write failed.
Submission keeps its existing ambiguous-outcome and retry rules.
