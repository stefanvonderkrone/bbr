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
