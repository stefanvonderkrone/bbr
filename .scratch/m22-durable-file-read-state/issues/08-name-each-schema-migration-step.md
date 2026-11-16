# 08: Name each schema migration step so two branches cannot share a version

Status: ready-for-agent
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

## Lands in M22

The operator decided on 2026-11-16 that this ticket lands in M22 before the merge into `main`.

## Agent brief

### Data shape

Each migration step is a record with a name and its SQL:

```zig
const Step = struct { name: [:0]const u8, sql: [:0]const u8 };
const migrations = [_]Step{ ... };
```

The store records each applied name in one table:

```sql
CREATE TABLE schema_steps (name TEXT PRIMARY KEY) WITHOUT ROWID;
```

The names of the eleven legacy steps, in array order:

| Version | Name | What the step makes |
| --- | --- | --- |
| 1 | `drafts` | The `drafts` table (`schema_v1`) |
| 2 | `draft_range_anchors` | `anchor_start_from` and `anchor_start_to` |
| 3 | `draft_review_scope` | The `drafts` rebuild with `workspace` and `repository` in the key |
| 4 | `submission_runs` | `submission_runs` and `one_active_submission` |
| 5 | `review_repository_aliases` | `review_repositories`, `review_repository_aliases`, `draft_temp_ids` |
| 6 | `draft_snapshots` | The three `snapshot_*` columns |
| 7 | `draft_comment_scope` | `scope_kind` and `file_source_commit` |
| 8 | `submission_run_items` | `submission_run_items` |
| 9 | `submission_retries` | The retry columns and `submission_retry_carryovers` |
| 10 | `posted_drafts` | `posted_drafts` |
| 11 | `file_read_receipts` | `file_read_receipts` |

A name never changes after a build that applies it exists.
A renamed step runs again on every store that recorded the old name.

`PRAGMA user_version` stops at 11 (`legacy_version`).
bbr builds without this ticket, such as the other milestone Worktrees, read it.
A new store must reach 11 so that those builds open it.
A step after step 11 does not write `user_version`.

### What to build

1. Replace `migrations` with the `Step` array above. Step 11 creates only `file_read_receipts`, with a plain `CREATE TABLE`. The bootstrap below now owns the old M22 shape of ticket 07, so step 11 no longer repeats the SQL of step 10.
2. `migrate` takes no write lock when `schema_steps` exists and holds every name. Check `sqlite_master` first, because a `prepare` on a missing table records a diagnostic.
3. Otherwise `migrate` runs the bootstrap in its own `BEGIN IMMEDIATE` transaction, then each step whose name is not recorded, in array order.
4. The bootstrap reads `sqlite_master` inside the lock. When `schema_steps` exists, it does nothing. Otherwise it creates the table and records these names:
   - the names of steps 1 to `min(user_version, 9)`, because every branch agrees on steps 1 to 9;
   - `posted_drafts` when that table exists;
   - `file_read_receipts` when that table exists.
5. `migrateStep` takes a `Step`. Inside `BEGIN IMMEDIATE`, it reads whether the name is recorded. If not, it runs the SQL and inserts the name. Then it sets `user_version` to the length of the longest prefix of the legacy steps whose names are recorded, when that length is higher than the current value. All of this is one transaction.
6. A `comptime` block rejects an empty name and a repeated name. The error names `migrations` in `src/persist/sqlite_store.zig`.
7. Each SQLite result of the new code passes through `SqliteStore.native` (AGENTS.md rule). Bind the name or check at `comptime` that it holds only `[a-z0-9_]`.
8. `downgrades` and `downgradeTo` also delete the name of each undone step. A test fakes a store from before this ticket with `downgradeTo` and then `DROP TABLE schema_steps`. A test that needs a version below 7 applies the legacy SQL and `user_version` directly.
9. `tests/store_message_cli_test.py` fakes a current store with no tables. After this ticket, that store needs `schema_steps` with every name of the reference store. The check expects `["schema_steps"]` as the only table.
10. `tests/store_migration_race_cli_test.py` also compares the sorted names in `schema_steps` with the reference store. Add rounds that start four processes on a store from before this ticket in the old M22 shape: the reference store without `schema_steps` and `posted_drafts`, at version 10.
11. Write ADR 0018, "A schema migration step has a name that the store records". It records the three options of the 2026-11-16 triage below, the frozen `user_version`, and the bootstrap.
12. Add a row to the rules table in `AGENTS.md`: a new step appends one named `Step`, a name never changes, and only a legacy step writes `user_version`. Name the `comptime` check and the tests below.
13. Update the SQLite schema section and the acceptance list of `SPEC.md`.

### Acceptance criteria

- [ ] A store that a build with steps "legacy + `branch_a`" migrated, opened by a build with steps "legacy + `branch_b` + `branch_a`", has both tables, both names, and every earlier Draft.
- [ ] A store from before this ticket at each version 0 to 11 opens with every one of the eleven names recorded, `user_version` 11, and every Draft.
- [ ] The old M22 shape (version 10, `file_read_receipts`, no `posted_drafts`, no `schema_steps`) opens with both tables, its Draft, and its receipt, with the plain `CREATE TABLE` of step 11.
- [ ] Two connections that bootstrap and migrate the same store from before this ticket both succeed, and each name is recorded once.
- [ ] A store at every name opens without `BEGIN IMMEDIATE`.
- [ ] A step after step 11 leaves `user_version` at 11.
- [ ] A repeated or empty name in `migrations` fails to compile.

### Tests that fail on the current code

The triage ran this test on `3413b2a0`. It fails at the third `migrateStep` with `error.Reported` from `exec`, because the version of `branch_b` hides it and `branch_a` runs a second time.

```zig
test "M22 read a step that one branch build applied does not hide the step another branch put at its version" {
    // open a new store with SqliteStore.open
    // migrateStep(schema_version + 1, "CREATE TABLE branch_a (x INTEGER);")   // build of branch A
    // migrateStep(schema_version + 1, "CREATE TABLE branch_b (x INTEGER);")   // merged build: B at the same version
    // migrateStep(schema_version + 2, "CREATE TABLE branch_a (x INTEGER);")   // merged build: A after B
    // exec "INSERT INTO branch_b VALUES (1);"
}
```

After this ticket, the test calls `migrate` with two `Step` lists, so `migrate` must take its list as a parameter in tests. The expectation stays: both tables exist and both names are recorded.

Also add, each named `M22 read ...` so that `zig build test-file-read` runs it:

- the bootstrap of a store from before this ticket at each version 0 to 11, with one Draft from version 1 up;
- the old M22 shape test of ticket 07, unchanged, which must pass with the plain step 11;
- two connections that bootstrap the same store, in the shape of "M22 read a migration step that another process already applied is skipped";
- a step after step 11 that leaves `user_version` at 11.

Each of these fails on `3413b2a0`, because `schema_steps` does not exist there.

### Live proof

Never open, copy, or change the operator's store.
Use a new `XDG_STATE_HOME` with mode 700 for each store, a scratch Git repository, and detached Worktrees for the old builds.

1. Make three stores with old builds. Author one Draft in each, and mark one File read where the build can.
   - `9231fcb9`: the old M22 shape, version 10 with `file_read_receipts`.
   - `main` at `3b290393`: version 10 with `posted_drafts`.
   - this branch at `3413b2a0`: version 11 with both tables.
2. Open each store with the ReleaseSafe build of this ticket. Expect no stderr, the old Draft, the read mark, eleven names, `user_version` 11, and `PRAGMA integrity_check` `ok`.
3. Open each store again with the `3b290393` and `3413b2a0` builds. Expect no "drafts won't persist" message.
4. Make two scratch branches from this ticket. One appends step `branch_a`, the other appends step `branch_b`. Run each build on its own copy of the store from step 2. Merge both branches and run the merged build on both copies. Expect both tables and both names in each copy, and no stderr.
5. Run `tests/store_migration_race_cli_test.py` through `zig build test-cli`.
6. Remove the Worktrees, state directories, and tmux sessions that the proof made.

### Checks

- `zig build test-file-read`
- `zig build test --summary all`
- `zig fmt --check src build.zig tests`
- `python3 tools/check_agent_docs.py`
- Manual: duplicate one name in `migrations` and confirm the compile error, then revert.

### Out of scope

- A down-migration in production. bbr has none today, and `downgrades` stays a test helper.
- A check that compares the schema of a store with a new store (rejected above).
- A content hash per step (option b of the triage below).

## Comments

### 2026-11-16 filed

The operator approved this follow-up during the work on ticket 07.

### 2026-11-16 triage: named steps, ready for an agent

The triage did not open the operator's store.

**Premise.** The premise holds, and the collision happened once.
A script read `src/persist/sqlite_store.zig` in all 575 commits that change it on every branch.
It listed the `CREATE TABLE` and `ALTER TABLE` statements of the migrations in order.
The commits have 12 distinct lists. Every list agrees on steps 1 to 9.
The lists differ only at version 10 (`file_read_receipts` or `posted_drafts`) and at the in-place edit of step 11 by ticket 07.
Every other Worktree branch, `main` included, ends at version 10 with `posted_drafts`. No other branch adds a step today.

**The real failure.** Two branches each append a different step at the same new version.
The merge conflicts in the array, and the person who merges puts one step at N and the other at N + 1.
The merged code is correct. A store that a build of one branch migrated before the merge is not.

| Option | What it catches | Where | What the operator sees | Cost |
| --- | --- | --- | --- | --- |
| (a) Named steps in `schema_steps`, with a bootstrap | Two steps at one version: each store applies the names it lacks. A repeated name after a merge fails to compile. | Open time, and compile time for a repeated name | Nothing. The store opens with every step. | One table, one bootstrap, a `Step` record, test helper changes, two CLI test updates |
| (b) Keep `user_version` and pin a content hash for each version in the repository | An edit or reordering of a committed step on one branch | CI on the branch | For the real failure, nothing changes. The merge conflicts in the pin file too, the merge pins the new order, CI passes, and the old store stays wrong, as in ticket 07. | A pin file and a tool that writes it. It also rejects a legitimate repair such as ticket 07, which edited step 11. |
| (c) Both | (a), and also an edit of a step that a store already applied | Open time and CI | As (a) | (a) plus (b). The edit class has no occurrence in the history. |

Only (a) catches the real failure, because the wrong state lives in a store and no check on the merged code sees a store.
A hash recorded in the store instead of a name is (a) with a weaker key: a legitimate edit such as ticket 07 changes the hash and runs the step again.
So the triage recommends (a) alone.

The residual risks of (a):

- Steps from two branches run in a different order on different stores. Each branch can only create its own objects before the merge, so the steps commute. A later step that uses both comes after both in the array.
- Both branches pick the same name for different steps. The merged array then fails to compile. If the person who merges deletes one entry, the stores of that branch skip the other step. This needs two mistakes in a row.
- A branch that adds a step with `user_version`, before it merges this ticket, writes version 12 on a store that already has `schema_steps`. After its merge, that step runs again and the open fails. No branch adds a step today. Merge M22 into each milestone branch before that branch adds a step.

**Bootstrap.** A store without `schema_steps` gets its names in one `BEGIN IMMEDIATE` transaction:

| Store version | Names recorded |
| --- | --- |
| 0 | None. Every step runs. |
| 1 to 9 | Steps 1 to the version |
| 10 from `main` | Steps 1 to 9 and `posted_drafts`. `file_read_receipts` runs. |
| 10 from an old M22 build | Steps 1 to 9 and `file_read_receipts`. `posted_drafts` runs. |
| 11 | All eleven |

The bootstrap drops no table and changes no row, so every Draft and receipt stays.
It reads `sqlite_master` inside the lock, so a second process that waited on the busy timeout finds `schema_steps` and does nothing.
SQLite rolls back the `CREATE TABLE` and the inserts together, so a crash leaves a store without `schema_steps`, and the next open bootstraps again.

**An older build and down-migration.** bbr has no production down-migration. `downgrades` is a test helper.
Today a build opens a newer store without a check when `user_version` is at or above its own last version, and it ignores the newer tables.
After this ticket, `user_version` stops at 11, so every build without this ticket opens a store of this ticket as today.
A build with this ticket ignores a recorded name that it does not know and applies only the names that it lacks.

**ADR.** Yes. No ADR covers schema migration: 0003 and 0006 cover the SQLite seam and the vendored library.
The decision is hard to reverse, because stores record the names, and a frozen `user_version` surprises a reader without it.
`main` ends at 0014. M32 plans 0015, M28 has 0016, and M27 and M33 have 0017. So the next free number is 0018.

**Label.** `ready-for-agent`. The agent brief above specifies every decision.
