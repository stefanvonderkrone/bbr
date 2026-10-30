# 03: Show Directory progress and survive receipt-load failure

Status: ready-for-agent
Blocked by: 01
Spec: [M22 spec](../SPEC.md)

## What to build

A Directory row in the File Tree is bold while any descendant File is unread.
A collapsed Directory still shows whether it holds unread Files.
When bbr cannot load File Read Receipts, the Review still opens.
Every File then shows unread, and the status shows "File read state unavailable, all Files show unread".

## Scope

- Set `Entry.unread` for Directory entries in `file_tree.build` in `src/tui/file_tree.zig`.
  A Directory is unread when any descendant File is unread, also inside a collapsed Directory.
- Add no count and no new layout to Directory rows.
- In `Published.createInputs`, treat a `FileReadStore.load` failure as "every File unread".
  `error.OutOfMemory` still fails the candidate.
- Add `file_read_load_failed` and its text in `actionErrorText`.
  Show it after the Candidate Session publishes.
- When `Dependencies.file_reads` is null, show every File unread without a warning.

## Acceptance criteria

- [ ] A Directory entry is unread while any descendant File is unread, and regular when all descendant Files are read.
- [ ] A collapsed Directory entry follows the same rule.
- [ ] Marking the last unread File in a Directory makes the Directory row regular in the same Frame.
- [ ] Directory rows paint bold or regular cells by the same rule as File rows.
- [ ] A failing `load` publishes the Candidate Session with every File unread and shows `file_read_load_failed`.
- [ ] An `error.OutOfMemory` from `load` fails the Candidate Session and keeps the previous Session.
- [ ] After a load failure, `m` still marks a File read when `put` succeeds.
- [ ] A null `Dependencies.file_reads` shows every File unread with no warning.

## Tests that prove it

- File Tree tests in `src/tui/file_tree.zig`.
- Render tests in `src/tui/render.zig` for bold and regular Directory rows.
- Presentation tests in `src/tui/presentation.zig` for the load failure, the allocation failure, and the null store.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`
