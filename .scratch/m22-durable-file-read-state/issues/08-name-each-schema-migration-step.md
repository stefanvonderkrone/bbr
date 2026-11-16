# 08: Name each schema migration step so two branches cannot share a version

Status: needs-triage
Blocked by: none

## Summary

Two branches gave schema version 10 to different steps.
M22 used version 10 for `file_read_receipts` from `9231fcb9` (2026-10-30).
`main` used version 10 for `posted_drafts` from `92aef82f` (2026-11-05).
Every M22 build before the merge `768977a8` (2026-11-06) wrote a store at version 10 without `posted_drafts`.
Ticket 07 repairs that one store shape in migration step 11.
This ticket prevents the class.

The class: two branches give the same schema version to different steps, and a build of one branch migrates a real store before the merge.
A check on the merged code cannot see the defect, because the merged code is correct.
The wrong state is in a store that a pre-merge build wrote.

## What to build

Give each migration step in `SqliteStore.migrations` in `src/persist/sqlite_store.zig` a stable name, such as `posted_drafts` or `file_read_receipts`.
Record the name of each applied step in a `schema_steps` table, in the transaction of the step.
`SqliteStore.migrate` applies each step whose name is not recorded.
Two branches that add different steps then never collide, because each step has its own name.

A store that has a `user_version` and no `schema_steps` table needs a one-time bootstrap.
The bootstrap cannot trust `user_version` alone, because version 10 has two meanings.
It reads the tables and columns of the store and records the name of each step whose objects exist.

## Rejected for now

Compare the tables and columns of the migrated store (`sqlite_master` and `pragma_table_info`) with a `:memory:` store that the same build migrates.
Record a diagnostic that names the version and each missing or extra object.
This finds the wrong state at the first open, not at a later write.
It only reports the state and does not repair it, so it is rejected for now.

## Out of scope for M22

M22 ships the repair of ticket 07 only. Triage this ticket after the M22 merge.

## Comments

### 2026-11-16 filed

The operator approved this follow-up during the work on ticket 07.
