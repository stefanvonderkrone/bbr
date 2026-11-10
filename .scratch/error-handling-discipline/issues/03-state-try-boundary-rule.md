# State the try boundary rule

Status: resolved
Type: implementation
Blocked by: none
Parent: ../PRD.md

## Goal

One rule says where `try` stops.
Inside a module, code uses `try`.
Code catches only in a function that cannot return an error, or that owns a user-visible decision.
At that boundary, code records the failure once through a `diagnostics.Handle`, then restores state or shows the failure.

## Boundaries in bbr

- Worker task entry points.
- Presentation event and command handlers. Presentation is a typed command-producing state machine (`docs/adr/0012`).
- CLI `main`, through `exitFailure` in `src/main.zig`.
- The SQLite and HTTP seams that convert foreign codes into typed causes.

Ghostty uses the same split (`src/renderer/Thread.zig:193-197`, `threadMain` and `threadMain_`).

## Origin in release builds

A release build has no error return trace.
The `@src()` in a `diagnostic.Failure` is then the only origin.
Record at the deepest point that still has context, and propagate after that.
A higher layer must not record the same failure again.

## Work

1. Write the rule as an ADR under `docs/adr/`, with the boundary list and the reason.
2. Add a row to the `AGENTS.md` rule table. Name what enforces it. If nothing enforces a part of it, mark that part "Convention (no check)".
3. Add the rule to `.agents/skills/zig/runtime.md` or a new reference beside the zig skill.
4. Find a check for the rule. For example, a lint can reject a record through a `diagnostics.Handle` in a function that also returns the same error. Record the result in this issue, even when no check is possible.

## Acceptance

- The ADR and the rule table row exist.
- `python3 tools/check_agent_docs.py` passes.
- This issue states which part of the rule a check enforces.

## Completion

The operator chose the Zig compiler pattern over the text of this issue.
A boundary cannot tell a failure that a lower layer recorded from one that it did not record, so "record deep, and never record again" had no check.
`decisions-03.tsv` holds the measurements and each decision.

Changes:

- `a6ec8af` adds `Handle.fail` to `src/diagnostics.zig`. It records the Failure through `Handle.failure` and returns `error.Reported`. The test "diagnostics fail records the leaf cause once and propagates error.Reported" drives a leaf through a `try` caller and reads back exactly one record.
- `427fdb9` adds the record count to `tools/check_diagnostics.py`, the file `tools/diagnostic_record_baseline.txt` with 51 sites in 12 files, and five tests in `tests/check_diagnostics_test.py`. The catch baseline did not change.
- The commit that adds this section adds [ADR-0014](../../../docs/adr/0014-a-failure-is-recorded-once-and-error-reported-marks-it.md), the `AGENTS.md` rule-table row, `.agents/skills/zig/errors.md`, PRD decision 5, and [issue 06](06-record-once-through-fail.md).

What a check enforces:

- `tools/check_diagnostics.py` fails when a file gains a production `catch` or `errdefer` handler that records through `failure`, `record`, or `reportFailure` and then returns an error.
- The test in `src/diagnostics.zig` enforces that `Handle.fail` records once and returns `error.Reported`.
- No check enforces that a boundary skips `error.Reported` and records every other error once.
- No check sees a record outside a handler, such as a `SqliteStore.native` check before `return error.Exec`.

Checks:

- `zig build test` exited 0 before each commit.
  Before the docs commit, one run failed in the unrelated test "required failure awaits started Authenticated Account acquisition" in `src/tui/session.zig`, which expected 2 HTTP calls and found 3. No Zig source changed after `427fdb9`, and the next run passed.
- `python3 tools/check_agent_docs.py` passed before each commit.
- Each of eight mutations of the final check, such as dropping the `errdefer` rule or the nested-catch rule, failed at least one test in `tests/check_diagnostics_test.py`.

Review:

- A read-only review found five handlers that record and then return an error in a form the first check missed. Examples are `return @as(anyerror!void, err)` at `src/main.zig:356` and `return on_fail` at `src/git/client.zig:159`. It also found that the first check counted `src/highlight/user_grammar.zig:488` for the wrong prong, and that a test counted a record in one `switch` prong and a return in another prong as one site. The check now tests each return operand and each prong, and the count went from 46 to 51.
- The review found that the ADR defined a boundary in a way that left out the SQLite and HTTP seams. The ADR now names the seams as the second kind of boundary, which records a foreign result and fails upward through `fail`.
- The review noted that `RECORD` also matches `ErrorDetail.record` in `src/bitbucket/client.zig`. That call is in no counted handler today.
