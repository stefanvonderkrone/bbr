# 06: Finish the schema migration when two bbr processes start on a new store

Status: needs-triage
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
