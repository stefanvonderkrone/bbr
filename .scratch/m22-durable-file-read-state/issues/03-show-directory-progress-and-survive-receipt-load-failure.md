# 03: Show Directory progress and survive receipt-load failure

Status: resolved
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

- [x] A Directory entry is unread while any descendant File is unread, and regular when all descendant Files are read.
- [x] A collapsed Directory entry follows the same rule.
- [x] Marking the last unread File in a Directory makes the Directory row regular in the same Frame.
- [x] Directory rows paint bold or regular cells by the same rule as File rows.
- [x] A failing `load` publishes the Candidate Session with every File unread and shows `file_read_load_failed`.
- [x] An `error.OutOfMemory` from `load` fails the Candidate Session and keeps the previous Session.
- [x] After a load failure, `m` still marks a File read when `put` succeeds.
- [x] A null `Dependencies.file_reads` shows every File unread with no warning.

## Tests that prove it

- File Tree tests in `src/tui/file_tree.zig`.
- Render tests in `src/tui/render.zig` for bold and regular Directory rows.
- Presentation tests in `src/tui/presentation.zig` for the load failure, the allocation failure, and the null store.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`

## Completion

The changes are uncommitted. The runner commits them.

Changed paths:

- `src/tui/file_tree.zig`
- `src/tui/presentation.zig`
- `src/tui/render.zig`
- `src/tui/app.zig`
- `src/review/file_read.zig`
- `.scratch/m22-durable-file-read-state/issues/03-show-directory-progress-and-survive-receipt-load-failure.md`

Change summary:

- `file_tree.build` marks each tree node unread before it emits rows.
  An unread node marks its parent unread, so a collapsed Directory keeps the state of hidden Files.
- `loadFileReads` returns one `FileReadState` with the entries and a `load_failed` flag.
  A non-OOM `load` failure gives unread entries with their fingerprints.
  An `error.OutOfMemory` from `load` still fails the Candidate Session.
- `Published.file_reads` holds the `FileReadState`.
  The initial load and `acceptPreparedSession` set `file_read_load_failed` only after publication.
- `actionErrorText` gives the text "File read state unavailable, all Files show unread".
- `InMemoryFileReadStore.load_error` injects an exact `load` error, such as `error.OutOfMemory`.

Status precedence:
On the initial load, a recovery claim failure from `discoverRecovery` replaces the receipt load warning.
The recovery failure concerns a Durable Operation, so it is the more important message.
A replacement publication already clears every earlier `action_error`, so the warning replaces nothing there.

Checks:

- `zig fmt --check build.zig src tests` passes.
- `zig build` passes.
- `zig build test-file-read --summary all` passes 49 of 49 tests, 11 in one step and 38 in the other.
- `zig build test --summary all` passes 1422 of 1422 tests. The baseline was 1411.
- `python3 tools/check_agent_docs.py` passes.

Mutation proof:

- Directory propagation limited to top-level Files fails "M22 read Directories follow deep descendants through expanded and collapsed Directories" and "M22 read marking the last unread File makes its Directory regular in the same Frame".
- A replacement publication that drops the warning fails 2 receipt load failure tests.
- Both mutations were restored, and the checks above ran after the restore.

Review result:
Self-review found no open findings. The runner owns the independent code review.
