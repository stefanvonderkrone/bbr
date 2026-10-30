# 01: Mark text Files read across Session replacement

Status: ready-for-agent
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

- [ ] Equal diff text gives equal fingerprints, and other `@@` line numbers or Hunk header text give equal fingerprints.
- [ ] A changed Line, Hunk boundary, path, or change kind gives a different fingerprint.
- [ ] An added File, a removed File, and a pure rename each have a fingerprint.
- [ ] `InMemoryFileReadStore` and the SQLite adapter pass the same round-trip, replace, delete, and ReviewIdentity isolation tests.
- [ ] A version 9 database migrates to version 10, keeps its Drafts, and reopens without a second migration.
- [ ] The receipts table has no reference to any PendingReview table.
- [ ] An initial Session with no receipts shows every File unread in the File Tree.
- [ ] `m` on a Sidebar File row and `m` in the DiffPane mark the focused File read and store one receipt.
- [ ] `m` on a read File deletes its receipt and shows the File unread.
- [ ] A failing `put` keeps the File bold, and a failing `delete` keeps the File regular. Both report `file_read_save_failed`.
- [ ] An allocation failure while staging the toggle preserves the previous Frame and writes nothing.
- [ ] `m` on a DiffPane row without a File is refused, and `m` does nothing in `.sidebar_directory`.
- [ ] An unchanged refresh keeps read Files read, and a one-File change makes only that File unread.
- [ ] A refresh that only shifts Hunk line numbers keeps every File read.
- [ ] A PullRequest switch and a switch back restore the read state.
- [ ] A LocalReview Ref refresh to a new SourceRef commit keeps unchanged Files read.
- [ ] Two Reviews with equal paths and equal PullRequestIds in other Repositories do not share read state.
- [ ] Candidate Session preparation never calls `put` or `delete`, also with stale receipts and a superseded candidate.
- [ ] Unread File rows paint bold cells, and read File rows paint regular cells on the cursor and active rows in every built-in Theme.
- [ ] A `[keymap]` override can rebind and unbind `toggle_file_read`, and the Command Palette lists "Toggle File Read".

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
