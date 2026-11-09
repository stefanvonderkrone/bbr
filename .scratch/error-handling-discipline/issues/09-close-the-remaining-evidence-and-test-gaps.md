# Close the remaining evidence and test gaps

Status: resolved
Type: implementation
Blocked by: 04, 05, 07
Parent: ../PRD.md

## Goal

Issues 04, 05, and 07 are resolved, but their comments list gaps that no ticket tracks.
Each failure must keep its leaf evidence in its one record, and each changed failure path must have a test.

## Lost leaf evidence (issue 07)

- The Git exit code behind a failed local blob read. The `GitClient` vtable has no `diagnostics.Handle` argument, so the slot of the File side cannot reach the Git client.
- The Git exit code behind a Git Anchor transition failure. The resolver can run on more than one thread, so it cannot share one slot.
- The evidence behind a translated error, such as `ReviewerVerdictChangeFailed`. The evidence explains the client error, so the record of the translated name does not take it.
- The page of an item decode failure on a sequential list page.
- When both File sides fail with `error.OutOfMemory`, the failure of the new side has no record.

## Slot rules with no check (issue 07)

- A `Handle` with a slot behind a pointer, or inside a type-erased source such as the Client in a `BlobSource`, passes the spawn check of `diagnostics.concurrent`.
- Nothing checks that a fan-out moves a slot to the correct parent, or that it moves the slot at all.
- The spawn check runs only in a Debug build and only on spawns that tests reach. No test spawns the worker Session load.
- A slot keeps the last evidence that a client noted. A later record of the same error name can take older evidence. No path in bbr does this now.

## Missing tests (issues 04 and 05)

- The cancel paths of `pickerTickWorker`, the two `Group.await` cleanups, and the transport-error sleep of the blob retry have no test.
- The blob cancel test can miss the 100 ms sleep under load.
- The descending Anchor message has no test, because `spanFromLines` does not build a descending range.
- `createPersisted` with `error.DraftNotFound` has no UI test, because the store refuses a run that names a missing Draft.

## Acceptance

- Each lost item reaches the one record of its failure, or this issue states why it stays lost.
- Each slot rule has a check, or the `AGENTS.md` rule table marks it as a convention with its reason.
- Each listed path has a test that fails when its behavior breaks, or this issue states why no test can reach it.
- `zig build test` passes. The record baseline lists no file, and the catch baseline does not rise.

## Comments

### Return-statement lint recheck, 2026-11-09

The checker now checks all client error members in a complete return expression.
The multiline result and conditional return regression tests fail with the old checker and pass with the new checker.
The multiline `noted` acceptance test passes with both checkers.
The red logs are `issue09-lint-red-*.log` under `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/`.
The green log is `issue09-lint-green.log` in the same directory.
No new failure producer lacked a note.
The broader check also found the pure `classify` and `asApiError` mappings.
`classify` now names its mapped result before return, and `asApiError` casts the matched error instead of repeating it.
Neither mapping writes evidence, and `Client.send` still notes the rejection status.

### Triage, 2026-11-09

Ready for an agent. Each item names its source, its cause, and an outcome that the acceptance accepts, so no item needs the operator.
Work the items in this order, because the first ones carry the most risk:

1. Make the blob cancel test independent of the 100 ms sleep. A flaky test hides the next real failure.
2. Pass a `diagnostics.Handle` to the Git client for the local blob read, so the termination reaches the record of the File side. Treat the Anchor transition the same way only if each resolver thread can own its slot.
3. Add the missing cancel tests and the record for a second File side that fails with `error.OutOfMemory`.
4. Check each slot rule, or mark it as a convention in the `AGENTS.md` rule table with its reason.

An item can end as "stays lost" or "no test can reach it" when the issue states the reason.
The translated-error evidence and the stale-evidence item are the most likely to end that way.

### Recheck of two items, 2026-11-09

**Translated-error evidence: fixable, not "stays lost".**
`Handle.record` adds the slot evidence only when the recorded error matches the noted error (`Failure.explainedBy` in `src/diagnostic.zig`).
The only translated name with leaf evidence is `ReviewerVerdictChangeFailed`, on three paths:

- `bbr check-verdict` (`verdictChangeFailed` in `src/main.zig`) records the cause from `verdictChangeCause`, which is the client error. The evidence reaches the record.
- `bbr api set-verdict` with a transport cause (`runSetVerdict` in `src/api/pullrequests.zig`) prints at the leaf and records the transport error through `fail`. The evidence reaches the record.
- `bbr api set-verdict` with a Bitbucket rejection behind an unresolved change returns the plain `ReviewerVerdictChangeFailed`. The boundary records that name, so the record has no status. The rejection evidence also stays in the CLI slot. The test at `src/api/cli.zig` ("RateLimited", cause `error=ReviewerVerdictChangeFailed`) pins this gap.

The cause is in scope at that site. The fix follows ADR-0014: print the rejection message at the leaf and return `fail(.execute, .{ .zig = transport })`, as the transport branch does.

**Stale evidence: no proven path, but the precondition exists. Not a convention yet.**
A record takes old evidence only when two things happen in one slot lifetime:

1. A client notes an error, and the caller handles it without a record. Example: `executeCommentDelete` in `src/tui/presentation_adapter.zig` treats `error.NotFound` as an outcome.
2. Later, the same error name is recorded with no new note.

Every HTTP failure notes through `Client.send`, and every Git failure notes through `runRaw`, so step 2 needs a producer that does not note.
These producers exist: the structural `return error.MalformedResponse` sites in `src/bitbucket/client.zig` (the account UUID check, the repeated next URL, and the page checks in `PagedLists`), and the input checks that return `error.BadRequest`.
No production `return error.NotFound` exists outside the client.
Each TUI worker builds its `PresentationSinkContext` per work item, so a slot lives for one task. The CLI slot lives for one command.
I found no path that does step 1 and step 2 for the same name in one slot. I did not prove that no such path exists.

Fix: each structural `MalformedResponse` site notes its own evidence, so every client error return writes a fresh note. A line check in `src/bitbucket/client.zig` can enforce that each `return error.` of a client error is next to a note.

## Completion

Commits on `feat/evidence-gaps`, in order. Each one builds alone, and each passes `zig build`, `check_diagnostics.py`, `check_error_comparisons.py`, and `check_task_spawns.py`. The decision log is `decisions-09.tsv`. The red logs are under `/private/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/issue09-*.log`.

- `2a8df48`: the blob cancel test does not depend on the retry delay. The retry `Io` waits on an `Event` that nobody sets, so only the cancel ends the wait. The old test fails under a 150 ms delay of the main thread. The new test passes under the same delay. The test also covers the transport-error wait of the blob retry. When that prong returns `null`, the test fails.
- `dde0b99`: `bbr api set-verdict` with a Bitbucket rejection behind an unresolved change prints the same message at the leaf and records the client error through `fail`. The record holds the HTTP status, and the CLI slot ends empty. `ErrorDetail.reported_error` had no other user, so it is gone. The user-visible text does not change.
- `91ab5e6`: every client error return in `src/bitbucket/client.zig` goes through `noted`. An input check notes `phase=prepare`, and a response with the wrong structure notes `phase=validate`. An item decoder that can reject an item takes the page handle, so an item decode failure on a sequential list page names its page. `Handle.explain` stays as it is. A record of an unrelated error must not drop the evidence of the next record (the test "diagnostics a boundary record takes the leaf evidence of its own error once").
- `3e98c30`: `tools/check_diagnostics.py` rejects a return of an `ApiError` member in `src/bitbucket/client.zig` that does not go through `noted`. On the `client.zig` of `dde0b99` it rejects 32 returns, such as the account UUID check and the author `Forbidden` result.
- `0577024`: `GitClient.diff` and `GitClient.blob` take the handle of their caller. A local blob read records its Git termination with its File side. Each Anchor transition read owns a slot on its stack, so a resolver on any thread keeps its own evidence.
- `8ddccd4`: when both File sides fail with `error.OutOfMemory`, the new side's failure has its own record. The catch baseline of `src/tui/file_enrichment.zig` goes from 1 to 0.
- `2af60e2`: tests for the cancel of `pickerTickWorker` in its wait and in a post to a full event queue, and for a terminal recovery claim whose run names a missing Draft. The run comes from a store `active_submission` that adds the missing Draft, because the store refuses such a run.
- `b827855`: a test runs `presentationLoadWorker`, so the Debug spawn check reaches the worker Session load. A worker that spawns its load with its own slot panics in this test.
- The last commit updates `AGENTS.md`, ADR-0014, `docs/diagnostic-logging.md`, and this issue.

Items that stay open, with the reason:

- The two `Group.await` cleanups have no cancel test. In `listPagesConcurrent`, the cleanup runs under `swapCancelProtection(.blocked)` whenever a task started, and an empty group returns before any cancel point (`std/Io.zig:1283`). So `error.Canceled` cannot reach that prong. `src/benchmark/file_acquisition.zig` has no test module.
- The descending Anchor message has no UI test. `spanFromLines` returns `NonContiguous` for rows that do not ascend, so `reanchorCandidate` cannot build a descending range. The `candidateError` mapping and the status text have unit tests.
- A `Handle` with a slot behind a pointer or a type-erased source, a slot moved to the wrong parent, and a spawn that no test reaches stay conventions in `AGENTS.md`, with their reasons.
- The test of a canceled post shows that the worker ends without its tick. The `io.recancel()` call in that prong has no effect that a test can see, because the worker returns right after it.

Baselines: the catch baseline goes from 36 to 35. The record baseline lists no file.

Checks: `zig build test` exit 0 on aarch64-macos after the last code commit, and `python3 tools/check_agent_docs.py` passes.

Review: no separate reviewer ran in this session. The red and green runs are the evidence for each item.
