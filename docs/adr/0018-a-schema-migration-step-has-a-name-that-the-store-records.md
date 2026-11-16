# A schema migration step has a name that the store records

Two branches gave schema version 10 to different migration steps. M22 used version 10 for `file_read_receipts` from `9231fcb9`, and `main` used version 10 for `posted_drafts` from `92aef82f`. The merge put the M22 step at version 11, and the merged code was correct. But an M22 build from before the merge wrote a real store at version 10 without `posted_drafts`. The merged build skipped `posted_drafts` on that store. No check on the merged code can see that defect, because the wrong state is in a store. So each migration step in `SqliteStore.migrations` in `src/persist/sqlite_store.zig` has a stable name. The store records the name of each step that it applied.

## Decision

- A step is a `Step` record with a `name` and its `sql`. A new step appends one `Step` to `migrations`.
- The store records each applied name in `schema_steps (name TEXT PRIMARY KEY) WITHOUT ROWID`, in the same transaction as the step.
- `migrate` applies each step whose name the store has not recorded, in array order.
- Each step runs in its own `BEGIN IMMEDIATE` transaction. It reads the recorded names again inside the lock, so a step that another process applied runs once.
- A store that records every name opens with reads only, without a write lock.
- A name never changes after a build that applies it exists. A renamed step runs again on every store that recorded the old name.
- `stepError` fails the build on an empty name, a name with a character outside `[a-z0-9_]`, and a repeated name. It also fails on `COMMIT` or `user_version` in step SQL outside literals and comments, because `migrateStep` owns the transaction and the version.

### `user_version` stops at 11

bbr builds without named steps, such as the builds of other milestone Worktrees, read only `PRAGMA user_version`. They open a store without a check when the version is at or above their own last version. So the first eleven steps, the legacy steps, still write `user_version`, and a new store reaches 11. A step after step 11 does not write `user_version`. A legacy step sets the version to its position when the version is lower. The loop records the steps before it in earlier transactions, so the version always names recorded steps.

### Names for a store from before this decision

A store without `schema_steps` has only `user_version`, and version 10 has two meanings. Every step transaction first reconciles the recorded names with the objects of the store:

- It creates `schema_steps` when the table is missing.
- It records the names of steps 1 to `min(user_version, 9)`, because every branch agrees on steps 1 to 9.
- It records `posted_drafts` when that table exists, and `file_read_receipts` when that table exists.

The reconciliation drops no table and changes no row, so every Draft and receipt stays. It runs in every step transaction, not once. An older build can migrate a store by `user_version` after a newer build created `schema_steps`, for example after a crash between two steps. The next step transaction then records the names of the steps that the older build applied.

## Considered options

The triage on 2026-11-16 compared three options.

| Option | Result for the real failure |
| --- | --- |
| (a) Named steps in `schema_steps`, with names for older stores | Each store applies the names it lacks. The store opens with every step. |
| (b) Keep `user_version` and pin a content hash for each version in the repository | Nothing changes. The merge also conflicts in the pin file. The person who merges pins the new order, and CI passes. The old store stays wrong. The pin also rejects a legitimate repair such as ticket 07, which edited step 11. |
| (c) Both | (a), plus a check for the edit of an applied step. That edit has no occurrence in the history. |

Only (a) catches the real failure, because the wrong state lives in a store, and no check on the merged code sees a store. A content hash recorded in the store in place of the name is (a) with a weaker key. A legitimate edit such as ticket 07 changes the hash and runs the step again.

## Consequences

- Steps from two branches can run in a different order on different stores. Before the merge, each branch can only create its own objects, so the steps commute. A later step that uses the objects of both comes after both in the array.
- If two branches pick the same name for different steps, the merged array fails to compile.
- A branch that adds a step with `user_version` before it merges this decision writes version 12 on a store that has `schema_steps`. After its merge, that step runs again and the open fails. Merge M22 into a milestone branch before that branch adds a step.
- `reconcile` reads the tables `posted_drafts` and `file_read_receipts` as the names of steps 10 and 11 on every migration. A later step never creates a table with one of those names again.
- `downgrades` and `downgradeTo` are test helpers. bbr has no production down-migration.
- Other milestone branches use the numbers 0015 to 0017, so this ADR is 0018.
