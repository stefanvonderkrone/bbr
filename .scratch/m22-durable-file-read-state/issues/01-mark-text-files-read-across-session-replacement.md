# 01: Mark text Files read across Session replacement

Status: resolved
Blocked by: none
Spec: [M22 spec](../SPEC.md)

## What to build

A reviewer presses `m` on a File in the Sidebar or the DiffPane.
The File changes from bold to regular weight in the File Tree.
The mark survives a quit, `R`, a PullRequest switch, and a LocalReview Ref refresh.
A File whose Hunk Lines change becomes bold again, and the other Files stay read.
Pressing `m` on a read File makes it unread again.

This slice covers text Files.
A binary File gets the same treatment in ticket 02.
Until then, the fingerprint treats every binary File as unverifiable.

## Scope

- Add `src/review/file_read.zig` with `FileReviewFingerprint`, `fingerprint`, `FileReadReceipt`, `FileReadStore`, and `InMemoryFileReadStore`.
  Export them from `src/root.zig` under `bbr.review`.
- Implement the fingerprint encoding from the "File Review Fingerprint" section of the spec, without the blob id part.
  A File with a binary side returns null in this slice.
- Add migration version 10 and `SqliteStore.fileReadStore()` in `src/persist/sqlite_store.zig`.
- Add `Dependencies.file_reads` and `Published.file_reads` in `src/tui/presentation.zig`.
  Load receipts in `Published.createInputs`, as the spec describes.
  In this slice, a `load` failure fails the Candidate Session. Ticket 03 adds the fallback.
- Add `Entry.unread` to `src/tui/file_tree.zig` for File entries.
  Paint the row weight in `drawFileTree` in `src/tui/render.zig`.
- Add `Action.toggle_file_read`, its `m` binding, its contexts, and its Command Palette entry.
- Add `Published.toggleFileRead` with stage, persist, and publish ordering.
- Add `file_read_save_failed` and `file_read_unverifiable` with their texts in `actionErrorText`.
- Wire `SqliteStore.fileReadStore()` into `Dependencies.file_reads` in `src/tui/app.zig`.
- Add the `test-file-read` build target with the filter `M22 read`.

## Acceptance criteria

- [x] Equal diff text gives equal fingerprints, and other `@@` line numbers or Hunk header text give equal fingerprints.
- [x] A changed Line, Hunk boundary, path, or change kind gives a different fingerprint.
- [x] An added File, a removed File, and a pure rename each have a fingerprint.
- [x] `InMemoryFileReadStore` and the SQLite adapter pass the same round-trip, replace, delete, and ReviewIdentity isolation tests.
- [x] A version 9 database migrates to version 10, keeps its Drafts, and reopens without a second migration.
- [x] The receipts table has no reference to any PendingReview table.
- [x] An initial Session with no receipts shows every File unread in the File Tree.
- [x] `m` on a Sidebar File row and `m` in the DiffPane mark the focused File read and store one receipt.
- [x] `m` on a read File deletes its receipt and shows the File unread.
- [x] A failing `put` keeps the File bold, and a failing `delete` keeps the File regular. Both report `file_read_save_failed`.
- [x] An allocation failure while staging the toggle preserves the previous Frame and writes nothing.
- [x] `m` on a DiffPane row without a File is refused, and `m` does nothing in `.sidebar_directory`.
- [x] An unchanged refresh keeps read Files read, and a one-File change makes only that File unread.
- [x] A refresh that only shifts Hunk line numbers keeps every File read.
- [x] A PullRequest switch and a switch back restore the read state.
- [x] A LocalReview Ref refresh to a new SourceRef commit keeps unchanged Files read.
- [x] Two Reviews with equal paths and equal PullRequestIds in other Repositories do not share read state.
- [x] Candidate Session preparation never calls `put` or `delete`, also with stale receipts and a superseded candidate.
- [x] Unread File rows paint bold cells, and read File rows paint regular cells on the cursor and active rows in every built-in Theme.
- [x] A `[keymap]` override can rebind and unbind `toggle_file_read`, and the Command Palette lists "Toggle File Read".

## Tests that prove it

- Fingerprint fixtures in `src/review/file_read.zig`.
- Shared store cases in `src/review/file_read.zig` and `src/persist/sqlite_store.zig`.
- The migration test from version 9 in `src/persist/sqlite_store.zig`.
- Presentation tests in `src/tui/presentation.zig`, including "M22 read Candidate Session preparation never writes File Read Receipts".
- The render test "M22 read the File Tree weight follows File Read State on every row" in `src/tui/render.zig`.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`

## Completion

The changes are uncommitted in the Worktree `/Volumes/Work/t3-code/m22-durable-file-read-state`.
The runner reviews and commits them.

### Change summary

- `src/review/file_read.zig` is new.
  It holds `FileReviewFingerprint`, `fingerprint`, `FileReadReceipt`, `FileReadStore`, and `InMemoryFileReadStore`.
  It also holds `expectStoreContract`, the shared store cases that both adapters run.
  A File with a binary side has no fingerprint in this slice.
- `src/root.zig` exports the new names under `bbr.review`.
- `src/persist/sqlite_store.zig` adds migration version 10 and `SqliteStore.fileReadStore()`.
  A stored fingerprint that is not 32 bytes long makes its receipt absent.
- `src/tui/file_tree.zig` adds `FileReadEntry` and `Entry.unread`.
  `file_tree.build` takes the File Read State of each File.
  Directory entries keep `unread = false` until ticket 03.
- `src/tui/render.zig` sets the bold attribute of every File Tree cell from `Entry.unread`.
- `src/tui/presentation.zig` adds `Dependencies.file_reads`, `Published.file_reads`, `Published.toggleFileRead`, and the two `ActionError` values.
  `Published.createInputs` loads the receipts after the PendingReview load.
  In this slice, a failed load fails the Candidate Session as `pending_review_load_failed`.
  The toggle and `rebuildFileTree` share `stageFileTree`.
  The staged `DisclosureInputs` carry the File Read State, so a worker build that started before the toggle retries with the new state.
- `src/tui/action.zig`, `src/tui/keymap.zig`, and `src/tui/list_overlay.zig` add `toggle_file_read`, the `m` binding, its contexts, and the Command Palette entry.
- `src/tui/app.zig` adds the two status texts and `RunCtx.file_reads`.
  `src/main.zig` passes `SqliteStore.fileReadStore()` for the remote, local, and demo runs.
- `build.zig` adds `test-file-read`, which runs the `M22 read` tests of the `bbr` module and of the executable.
- `src/benchmark/main.zig` and `src/benchmark/p1_actions.zig` pass File Read State to `file_tree.build`.
- The v8 migration fixture in `src/persist/sqlite_store.zig` drops `file_read_receipts`, because a version 7 database has no such table.

### Checks

- `zig fmt --check build.zig src tests`: exit 0.
- `zig build`: exit 0.
- `zig build test-file-read --summary all`: 9/9 steps succeeded, 32/32 tests passed.
- `zig build test --summary all`: 24/24 steps succeeded, 1405/1405 tests passed. The baseline before M22 was 1378.
- `python3 tools/check_agent_docs.py`: pass.

### Review

Mutation checks prove that the new tests fail when the behavior breaks:

- A load that ignores the fingerprint fails the refresh, LocalReview, and Candidate Session tests.
- A store write during Candidate Session preparation fails seven Presentation tests, including "M22 read Candidate Session preparation never writes File Read Receipts".
- A File Tree weight that keeps the `Theme.sidebar_selected` bold fails "M22 read the File Tree weight follows File Read State on every row".
- Staged Frame inputs without the new File Read State fail "M22 read a worker Frame started before a toggle publishes the new File Read State".

## Comments

### Review fix M22-3: two Files with one display path

A type change gives a removed File and an added File with one display path.
The store holds one receipt for each path, so the two Files shared one receipt.
`loadFileReads` now gives no fingerprint to a File whose display path occurs twice in the Diff.
Both Files stay unread, and `m` on either File reports `file_read_unverifiable` and writes nothing.
We chose this conservative option over a new store key, because it needs no schema change.

Proof: the test "M22 read two Files with one display path ignore a matching receipt and m on each is file_read_unverifiable" in `src/tui/presentation.zig`.
It failed on commit `372ef40` and passes after commit `1f19168`.
A removed guard fails the same test.

### Review fix M22-7: a change to only the end-of-file newline

The parser dropped the `\ No newline at end of file` marker.
`Line.no_newline_at_eof` in `src/diff/model.zig` now records the marker.
`fingerprint` hashes one extra tag after each flagged Line.
A Line without the flag hashes as before, so stored receipts stay valid.

Proof: the tests "M22 read a no newline marker flags the Line before it" in `src/diff/parser.zig` and "M22 read a change to only the end-of-file newline gives a different fingerprint" in `src/review/file_read.zig`.
Both failed on commit `21b800c` and pass after commit `148ab30`.

### Review fix M22-4: busy timeout and migration race

`SqliteStore.open` now sets a busy timeout of 2000 ms before it migrates.
Writes run on the TUI thread, so the wait stays short.
Each migration is one entry in `SqliteStore.migrations`.
`migrateStep` runs the entry in `BEGIN IMMEDIATE` and reads `user_version` again inside the transaction.
A step that another process applied is skipped.
The fix covers every step, not only v10, because the race was the same for each step.

Proof: the tests "M22 read SqliteStore.open sets a busy timeout so a write waits for another bbr process" and "M22 read a migration step that another process already applied is skipped" in `src/persist/sqlite_store.zig`.
Both failed on commit `3e1d146` and pass after commit `a445646`.
The tests use one thread, because the build compiles SQLite with `SQLITE_THREADSAFE=0`.
A first version used two threads, and we removed it because it was a data race.
