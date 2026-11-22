# Stabilize the Comments failure RawDiff test

Status: needs-triage
Blocked by: none

## Problem

The test "Comments failure prevents later RawDiff acquisition" in `src/tui/session.zig` failed once in CI:

```text
error: 'tui.session.test.Comments failure prevents later RawDiff acquisition' failed:
       expected 3, found 4
```

The failure was in the `test (macos-x86_64)` job of run 45015537323 for PR 42, on 2026-11-22.
PR 42 changed only `src/tui/presentation.zig`.
A rerun of the failed job passed.
No other failed run of the last 25 had this test.

The test releases fake HTTP responses through atomic flags and waits with `spinUntil`.
It expects that a failed Comments request stops the Session load before a fourth request, the RawDiff request, starts.
A count of 4 means that the RawDiff request started anyway.
It is not known whether this is a race in the test or a race in the Session load. That is a guess from one failure.

## Proposal

- Run the test in a loop on an x86_64 macOS host, or with the Zig thread scheduler under load, until it fails, and record the failure rate.
- Read the Session load to find out whether a RawDiff request can start after the Comments failure. If it can, the product has a race and the fix goes there. If not, the test waits on the wrong condition.

## Acceptance criteria

- [ ] The ticket records how often the test fails before the fix, and the cause.
- [ ] The test passes in a loop of at least 1000 runs.
- [ ] `zig build test` passes.
