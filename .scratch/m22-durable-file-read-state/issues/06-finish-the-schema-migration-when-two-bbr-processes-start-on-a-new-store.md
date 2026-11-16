# 06: Finish the schema migration when two bbr processes start on a new store

Status: resolved
Blocked by: none

## Summary

An earlier review session observed that a concurrent first start of two bbr processes stops the schema migration at version 4.
The observation was not written down in a ticket, so the exact reproduction is not recorded.

`SqliteStore.migrate` in `src/persist/sqlite_store.zig` reads `PRAGMA user_version` outside a transaction and then runs each step.
Two processes can both read the same old version and both run the same step.
The second process then fails, for example on `CREATE TABLE submission_runs` of version 4, because the table already exists.
Versions 1 to 3 also set `user_version` in a separate statement after the step, so a crash between the two leaves a step that runs again.
This explanation is inferred from the code, not reproduced.

A failed migration can leave the pending Draft store unusable, so this defect can lose Drafts.

## What to find

- A reproduction: two processes that open a new store at the same time, with the version that each one reaches.
- Whether a `BEGIN IMMEDIATE` around the version read and each step, or one transaction for the whole migration, fixes it.
- A test that fails on the current code.

## Comments

### 2026-11-16 filed

The operator filed this defect here so that a later PullRequest owns it.

### 2026-11-16 moved to M22

The operator moved this ticket from the enrichment rebuild follow-up, where it was ticket 13, to M22.
M22 already contains a fix: `3e1d1464` adds failing tests for the migration race, and `a4456464` runs each step under `BEGIN IMMEDIATE` and reads the version again inside the lock.
Check that those tests reproduce the defect of this ticket, then resolve this ticket with links to the two commits.

### 2026-11-16 triage: the M22 fix covers this defect

The fix in `3e1d1464` and `a4456464` covers this defect. The evidence follows.

The test in `3e1d1464` does not run the `migrate` function of `main`.
It copies the unlocked pattern of `main` for one step and runs it on two connections in one process.
It does not cover versions 1 to 3, and it does not start two processes.
So the triage ran a stronger test against both migration codes.

The test forks 2 or 4 child processes.
Each child waits on a pipe, then calls `SqliteStore.open` on the same new store.
The parent reads `PRAGMA user_version` through a raw connection after the children exit.
Each run has 200 rounds, and each round uses a new store.
The test uses `fork` because the vendored SQLite builds with `SQLITE_THREADSAFE=0`, so threads are not a valid model.

| Code | Processes | Failed opens | Final version per round |
| --- | --- | --- | --- |
| `main` at `3b290393` | 2 | 200 of 400 | 10 in 200 rounds |
| `main` at `3b290393` | 4 | 634 of 800 | 10 in 166 rounds, 0 in 34 rounds |
| M22 at `1a8930ae` | 2 | 0 of 400 | 11 in 200 rounds |
| M22 at `1a8930ae` | 4 | 0 of 800 | 11 in 200 rounds |

On `main`, every process that failed saw version 0 when it failed.
In 34 rounds every process failed, and the store stayed at version 0.
The triage did not see version 4. A stop at a lower version is the same defect, because the result depends on which process fails at which step.

On M22, each step and its `PRAGMA user_version` write run in one `BEGIN IMMEDIATE` transaction.
So a crash between the step and the version write of versions 1 to 3 cannot happen.
The busy timeout of 2000 ms makes a second process wait for the lock.

The fork test passes under `zig build` only when it prints nothing to stderr.
The triage did not commit it.

## Completion

- Fix: `a4456464` runs each migration step in `BEGIN IMMEDIATE`, reads `user_version` again inside the lock, and sets a busy timeout of 2000 ms before it migrates.
- Test: `3e1d1464` adds "M22 read a migration step that another process already applied is skipped" and "M22 read SqliteStore.open sets a busy timeout so a write waits for another bbr process".
- Check: the fork test above fails on `main` in every round and passes on M22 in every round.
- Check: `zig build test-file-read` passes on M22.
- Review: the triage of 2026-11-16 above.
- Gap: a migration that holds the lock for more than 2000 ms makes a waiting process fail. No current step is that slow on a small store. This is inferred, not measured.
