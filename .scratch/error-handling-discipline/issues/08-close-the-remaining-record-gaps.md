# Close the remaining record gaps

Status: needs-triage
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
