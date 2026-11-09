# Close the remaining evidence and test gaps

Status: ready-for-agent
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
