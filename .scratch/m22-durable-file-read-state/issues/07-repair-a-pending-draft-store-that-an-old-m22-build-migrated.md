# 07: Repair a pending Draft store that an old M22 build migrated

Status: resolved
Blocked by: none

## Summary

An earlier review session found the operator's real pending Draft store at schema version 10, but without the `posted_drafts` table that version 10 creates.
The observation was not written down in a ticket, so the exact evidence is not recorded.

In `SqliteStore.migrate` in `src/persist/sqlite_store.zig`, version 10 creates only `posted_drafts`.
A store at version 10 without that table means that another build set version 10 with a different step, or that a migration step was skipped.
A likely cause is a milestone branch that used version 10 for another migration before `main` assigned it. This cause is a guess.

Each later start skips the version 10 step, so a code path that writes `posted_drafts` fails on this store, and Drafts can be lost.

## What to find

- Which build set version 10 on this store. Do not open or change the operator's real store. Work on a copy only with the operator's permission.
- A repair for stores that are already in this state.
- A check that stops two branches from assigning the same schema version to different steps.

## Comments

### 2026-11-16 filed

The operator filed this defect here so that a later PullRequest owns it.

### 2026-11-16 moved to M22, cause found

The operator moved this ticket from the enrichment rebuild follow-up, where it was ticket 14, to M22.
The cause comes from M22 itself. At `9231fcb9` (2026-10-30), M22 used schema version 10 for `file_read_receipts`. `main` assigned version 10 to `posted_drafts` later, in `92aef82f` (2026-11-05). M22 now creates `file_read_receipts` in version 11.
A store that an old M22 build migrated is at version 10 with `file_read_receipts` and without `posted_drafts`. After the merge, the store skips `posted_drafts`, and version 11 can fail because `file_read_receipts` exists. This consequence is inferred, not reproduced.
M22 must repair such a store before the merge. Reproduce it on a store that the old build creates in a separate `XDG_STATE_HOME`. Never open or change the operator's real store.

### 2026-11-16 triage: reproduced, repair proven on a copy

The triage did not open the operator's store.
It made the old store with the old build in a separate `XDG_STATE_HOME`.

Reproduction:

1. Build `9231fcb9` in a detached Worktree and start `bbr local HEAD~1 HEAD` with a new `XDG_STATE_HOME`.
2. Author one Review-level Draft (`C`, text, `ctrl-d`) and mark one File read (`m`). Stop the process.
3. The store is at version 10. It has `file_read_receipts` with one receipt, one Draft, and no `posted_drafts`.
4. Start the current M22 build (`1a8930ae`, ReleaseSafe) on the same store.

Result on M22:

- bbr prints `bbr: could not open <state>/bbr/pending.db; drafts won't persist this session` and runs the Session on a `:memory:` store.
- The store stays at version 10, with the same tables, one Draft, and one receipt.
- Step 11 fails with `table file_read_receipts already exists`. The `sqlite3` CLI shows this message on a copy of the store.
- The message says that the Drafts of that Session do not persist. The earlier Draft stays on disk, but the Session reads the `:memory:` store. This effect is inferred from the fallback, not checked in the Session.

Result on `main` (`3b290393`): `SqliteStore.open` opens the same store at version 10, and an `INSERT INTO posted_drafts` fails.
`completeSubmissionImpl` writes `posted_drafts`, so a clean Submission completion on `main` fails on this store. This effect is inferred from the code, not run.

Which builds make this store: every M22 build from `9231fcb9` (2026-10-30) up to the merge `768977a8` (2026-11-06) sets version 10 with `file_read_receipts`.
The `file_read_receipts` table has the same columns and primary key in every M22 commit from `9231fcb9` to `1a8930ae`, after whitespace normalization.
So the old table and the current table are the same table.

Repair prototype, in a scratch Worktree only:

- Step 11 runs `CREATE TABLE IF NOT EXISTS posted_drafts (...)` with the SQL of step 10, then `CREATE TABLE IF NOT EXISTS file_read_receipts (...)`.
- The failing test below passes, and `zig build test-file-read` passes.
- The ReleaseSafe build on a copy of the old store: version 11, both tables, the old Draft, the new Session Draft, and the receipt. bbr prints no message.

The repair changes the migration, where the state breaks. The state is legitimate, because operator stores already hold it. So handling it in the migration is the root fix, not a guard.
The repair drops no table and rewrites no row, so every Draft and receipt stays.

## Agent brief

### What to build

Make migration step 11 in `SqliteStore.migrations` in `src/persist/sqlite_store.zig` accept the old M22 store.
Step 11 creates `posted_drafts` with `CREATE TABLE IF NOT EXISTS` and the same columns and primary key as step 10.
Then it creates `file_read_receipts` with `CREATE TABLE IF NOT EXISTS`.
The comment above step 11 says why: M22 builds before the merge `768977a8` set version 10 with `file_read_receipts` and no `posted_drafts`.
Step 10 stays unchanged. The `downgrades` table stays unchanged.

Update `SPEC.md` in this folder: the SQLite schema section and the acceptance list still name version 10 for `file_read_receipts`. They must name version 11.

### Acceptance criteria

- [x] A store at version 10 with `file_read_receipts`, one Draft, one receipt, and no `posted_drafts` opens at version 11 and keeps the Draft and the receipt.
- [x] After that open, `posted_drafts` accepts a row.
- [x] A store at version 10 from `main` (with `posted_drafts`, no `file_read_receipts`) still migrates to version 11. The existing test "M22 read a version 10 database migrates to version 11, keeps its Drafts, and reopens once" proves it.
- [x] A new store still reaches version 11.

### Test that fails on the current code

Add this test to `src/persist/sqlite_store.zig`. Its name starts with `M22 read`, so `zig build test-file-read` runs it.
It makes the old M22 shape with `downgradeTo(11)`, then drops `posted_drafts` and sets version 10.
The extra `exec` is the only way to make a state that no current migration makes. Say so in one comment.

```zig
test "M22 read a version 10 store that an old M22 build migrated reaches version 11 and keeps its Drafts and receipts" {
    // setup: open a new store, put one Draft and one receipt,
    // downgradeTo(&sqlite, 11), then exec "DROP TABLE posted_drafts; PRAGMA user_version = 10;"
    // expect: SqliteStore.open succeeds, userVersion is 11, the Draft body and the
    // receipt load, and "INSERT INTO posted_drafts VALUES ('w', 'r', 1, 1, 7);" succeeds.
}
```

On `1a8930ae` the test fails, because `SqliteStore.open` returns `error.Reported` from the `exec` of step 11.
The triage ran this test on the current code and on the prototype.

### Checks

- `zig build test-file-read`
- `zig build test`
- `python3 tools/check_agent_docs.py`
- Manual: build `9231fcb9`, make a store in a new `XDG_STATE_HOME` as in the reproduction above, then start the new build on it. Expect version 11, both tables, and no "drafts won't persist" message. Never use the operator's store.

### Out of scope

- The prevention of the class below. It needs its own ticket.
- The fallback to a `:memory:` store when the open fails. It exists on `main` too.

## Prevention of the class

The class: two branches give the same schema version to different steps, and a build of one branch migrates a real store before the merge.
A check on the merged code cannot see this, because the merged code is correct. The wrong state is in a store that a pre-merge build wrote.

The options, in the `correct` order:

1. Architecture. Give each step a stable name, such as `posted_drafts` or `file_read_receipts`. Record each applied name in a `schema_steps` table in the step's transaction. `migrate` applies each step whose name is not recorded. Two branches that add different steps then never collide. A store with `user_version` and no `schema_steps` table needs a one-time bootstrap that reads the tables, because version 10 has two meanings.
2. A check. After `migrate`, compare the tables and columns of the store (`sqlite_master` and `pragma_table_info`) with a `:memory:` store that the same build migrates. A difference records a diagnostic that names the version and the missing or extra objects. This finds the state at the first open, not at a later write, but it does not repair it.
3. A rule (no check): a pre-merge build uses a separate `XDG_STATE_HOME`. Nothing fails when someone skips it.

The triage recommends option 1 in a separate ticket after the M22 merge.
The class happened once, so option 2 alone is also defensible.

## Questions for the operator

- Did you run any M22 build other than the ones between `9231fcb9` and `768977a8` against your store? The repair assumes that the old M22 shape is the only foreign shape.
- Do you want the prevention as a new ticket now, and with option 1 or option 2?

### 2026-11-16 operator answers

The operator does not know whether a newer M22 build ran on the real store.
Every M22 build from `9231fcb9` makes the same `file_read_receipts` table, and step 11 creates each of its two tables only when it is missing.
So a store from any M22 build, older or newer, reaches version 11.
The operator approved the prevention as ticket 08, with option 1. Option 2 is rejected for now, because it only reports the state.

## Completion

- Failing test: `7747fb9b` adds "M22 read a version 10 store that an old M22 build migrated reaches version 11 and keeps its Drafts and receipts". On `7747fb9b` it fails, because `SqliteStore.open` returns `error.Reported` from the `exec` of step 11 in `migrateStep`.
- Fix: `046ccd0c` makes step 11 run `CREATE TABLE IF NOT EXISTS` for `posted_drafts` and `file_read_receipts`. Step 10 and `downgrades` stay unchanged. `SPEC.md` names version 11.
- Check: `zig build test-file-read` passes 59 of 59 tests after the fix.
- Check: `zig build test` passes, 51 of 51 steps and 1661 of 1661 tests.
- Check: `zig fmt --check src build.zig tests`, every `tools/check_*.py` that `build.zig` runs, and `python3 tools/check_agent_docs.py` pass.
- Manual check, in a separate `XDG_STATE_HOME` with mode 700 and a scratch Git repository. The operator's store was not opened.
  1. The `9231fcb9` ReleaseSafe build authored one Review-level Draft and marked `a.txt` read. The store was at version 10, with `file_read_receipts` and one receipt, one Draft, and no `posted_drafts`.
  2. The `63ce96c3` build on a copy printed `bbr: could not open <state>/bbr/pending.db; drafts won't persist this session` and showed no Draft. The copy stayed at version 10.
  3. The `046ccd0c` ReleaseSafe build printed nothing on stderr and showed the old Draft. A new Draft persisted after a restart, and the Session showed both Drafts.
  4. The store was then at version 11, with `posted_drafts`, `file_read_receipts`, both Drafts, and the receipt for `a.txt`. The File Tree showed `a.txt` read and `b.txt` unread.
- Related: `c5f1717b` adds the cross-process migration check of ticket 06. `0102fcd3` makes the store message check read the current schema version from bbr, because its literal `10` went stale with step 11.
- Review: code review of `63ce96c3..HEAD` on two axes, Standards and Spec. No finding blocked the change.
  - Standards: two sentences over 20 words, in the step 11 comment and in `SPEC.md`. Both are split.
  - Standards: step 11 repeats the `posted_drafts` SQL of step 10. It stays, because a migration step is fixed history.
  - Spec: the reference run in the store message check checked nothing. It now expects a version above 0.
  - Both: the race check ignores the exit code. It stays, because `bbr local` without a terminal exits with 1 and prints `error: NoDevice` on M22 and on `main`.
