# Close the remaining record gaps

Status: resolved
Type: implementation
Blocked by: 06
Parent: ../PRD.md

## Goal

Each failure has exactly one record in the diagnostic file.
Issue 06 left the gaps below, and its `## Comments` section has the details.

## Gaps

- A Reviewer Verdict change that stays unresolved after a lost connection has two records. This happens on the `bbr api` path and in `checkMutationRun`.
- `createInputs` turns a resolver error, such as `error.OutOfMemory`, into "unavailable" with no record.
- An early `try` exit before `PagedLists.finish` can leave other failed pages with no record.
- `detectRun` prints the Git error name with no record.
- No CLI test reads the record count of a refused `bbr api set-reviewer-verdict`.
- The `runPresentation` message for an initial load that fails with `error.Reported` has no test.

## Acceptance

- Each gap has a test that reads exactly one record, or the issue states why the gap is an expected outcome.
- `zig build test` passes.

## Completion

Each gap now has one record, or a test that reads one record for the path that issue 06 named.

- Unresolved Reviewer Verdict change after a lost connection (`a31bc7d`, `afaf727`). `ReviewerVerdictChangeResult.unresolved` now carries the cause, an `ApiError` or a transport error. A null value meant both "the cause has a record" and "there is no cause", so no caller could tell whether to record. The client records only a mutation cause that the result does not name. The TUI adapter, `runSetVerdict`, and `checkVerdict` each record the returned cause once. `runSetVerdict` and `checkVerdict` print a transport cause before they return `fail`. The issue named `checkMutationRun`, but the site was `checkVerdictRun` in `src/main.zig`.
- `createInputs` resolver error (`878ac05`). `createInputs` propagates the error with `try`. `GitAnchorResolver` already records each expected Git or parse failure and returns `.unavailable`, so only `OutOfMemory` escapes. The Presentation boundary records it once. Two uncaptured drops go, and the catch baseline falls from 55 to 53.
- Early exit before `PagedLists.finish` (`ee4dcda`). `PagedLists.deinit` runs on every exit through its `defer`. It records each failed page that is still in the coordinator state. `finish` releases the page whose failure it returns, so the caller's boundary records that one.
- `detectRun` probe (`103361f`). This is an expected outcome, not a gap. The probe lines only show what the GitClient sees. `startup.resolve` meets each error that the command needs again and fails, and `exitFailure` records it once. A probe error that resolution does not meet, such as a detached HEAD or a missing remote with an explicit Repository, does not fail the command. A record at the probe would give one condition two records. `tests/record_once_cli_test.py` reads one record for three failed `bbr detect` runs.
- Record count of a refused `bbr api set-verdict` (`a31bc7d`). The api boundary moved into `reportFailure`. The test "diagnostics a refused set-verdict shows its message and has one record" in `src/api/cli.zig` drives `runSetVerdict` through it for a lost connection, a stale SourceCommit, a rejection, and an unresolved rate limit. `tests/record_once_cli_test.py` reads one record for a set-verdict transport failure through the binary. The binary cannot reach a refusal without network access, because the transport uses TLS.
- `runPresentation` message for an initial load that fails with `error.Reported` (`a0b2067`). The message now goes through `ctx.io`. The test "diagnostics an initial load that the store reported shows its message and keeps one record" in `src/tui/app.zig` reads the message and the store's one record.

User-visible changes:

- An unresolved transport failure names its cause: `bbr api set-verdict: ReviewerVerdictChangeFailed: ConnectionResetByPeer`. `check-verdict` prints `bbr: ReviewerVerdictChangeFailed (<cause>)` in place of `error: ReviewerVerdictChangeFailed` and the trace.
- A resolver error, which is `OutOfMemory` in practice, fails a Session load with the out-of-memory message. Before, the Draft showed an unavailable scope.

Checks, each run after each commit:

- `zig build test`: exit 0.
- `python3 tools/check_diagnostics.py`: passes. The catch baseline is 53, down from 55. The record baseline lists no file.
- `python3 tools/check_agent_docs.py`: passes.

Each red run is in `decisions-08.tsv`. A read-only review of the whole diff found no path with zero or two records for one failure. Its notes about the write order and the restore cause are fixed in `afaf727`.

Remaining for issue 07: on the api path, an unresolved change whose cause is an `ApiError` still records `ReviewerVerdictChangeFailed`, not the rejection name. The message shows the rejection, and the TUI and `check-verdict` records name it.

