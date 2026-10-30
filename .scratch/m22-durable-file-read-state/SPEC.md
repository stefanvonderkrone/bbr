# M22 Durable File read state

Status: ready-for-agent
Milestone: M22

The [M22 brief](brief.md) records the approved decisions.
This spec turns the brief and the M22 section of [TODO.md](../../TODO.md) into buildable form.
The implementation tickets live in [issues](issues/).

## Problem Statement

A reviewer works through a PullRequest or a LocalReview File by File.
Today, bbr does not show which Files the reviewer already finished.
After a refresh, a PullRequest switch, or a restart, the reviewer must remember their progress.

A simple "done" flag is not enough.
When the author pushes a change to one File, that File needs review again.
A flag that survives the change hides new code from the reviewer.
A flag that resets on every push makes the reviewer stop using it.

## Solution

The reviewer presses `m` to mark the focused File read.
bbr stores a File Read Receipt in the local SQLite database.
The receipt carries the File Review Fingerprint of the File at the time of the mark.

The File Tree shows each unread File in bold and each read File at regular weight.
A Directory row is bold while any descendant File is unread.

Each Candidate Session reads the receipts and compares them with new fingerprints.
A File keeps its read state only while its review-visible change is the same.
The fingerprint ignores Hunk line numbers, so a pure line shift keeps the File read.
A changed File becomes bold again, and the other Files keep their state.

Pressing `m` on a read File makes it unread again.
A failed write leaves the visible state unchanged and shows a status message.
A failed receipt load shows every File unread and shows a warning.

## User Stories

1. As a reviewer, I want unread Files in bold in the File Tree, so that I see my remaining work.
2. As a reviewer, I want read Files at regular weight, so that finished Files fade back.
3. As a reviewer, I want `m` to mark the focused File read, so that I record progress with one key.
4. As a reviewer, I want `m` to work in the Sidebar on a File row, so that I can mark Files from the File Tree.
5. As a reviewer, I want `m` to work in the DiffPane, so that I can mark the File I just read.
6. As a reviewer, I want `m` on a read File to make it unread, so that I can correct a wrong mark.
7. As a reviewer, I want to configure the key for `toggle_file_read`, so that the binding fits my Keymap.
8. As a reviewer, I want the Command Palette to list the toggle, so that I can find it without the key.
9. As a reviewer, I want my read state to survive a quit and a restart, so that progress is durable.
10. As a reviewer, I want my read state to survive `R`, so that a refresh does not reset my work.
11. As a reviewer, I want my read state to survive a PullRequest switch, so that I can come back later.
12. As a reviewer, I want my read state to survive a LocalReview Ref refresh, so that local review works the same way.
13. As a reviewer, I want a changed File to become bold again, so that I never miss new code.
14. As a reviewer, I want unchanged Files to stay read after a push, so that one change does not reset everything.
15. As a reviewer, I want a destination merge that only shifts lines to keep Files read, so that merges do not create noise.
16. As a reviewer, I want a rename to count as a change, so that I review the new path.
17. As a reviewer, I want a removed File to have its own read state, so that I can confirm a removal.
18. As a reviewer, I want a binary File to become unread when its blob changes, so that binary updates are visible.
19. As a reviewer, I want a binary File without blob ids to stay unread, so that bbr never claims a check it cannot make.
20. As a reviewer, I want a clear message when bbr cannot verify a File, so that I know why `m` did nothing.
21. As a reviewer, I want a Directory row in bold while any descendant File is unread, so that collapsed Directories show remaining work.
22. As a reviewer, I want a failed write to keep the File bold, so that the screen never shows unsaved progress.
23. As a reviewer, I want a failed write to show a status message, so that I know the mark did not persist.
24. As a reviewer, I want a failed receipt load to still open the Review, so that storage trouble does not block review.
25. As a reviewer, I want a warning when receipts cannot load, so that I know the bold Files are a fallback.
26. As a reviewer, I want read state isolated per ReviewIdentity, so that equal paths in other Reviews never share progress.
27. As a reviewer, I want equal PullRequestIds in other Repositories kept apart, so that Repository scope stays correct.
28. As a reviewer, I want a RemoteReview and a LocalReview kept apart, so that local marks never leak into remote review.
29. As a reviewer, I want read state to stay on my machine, so that Bitbucket never sees it.
30. As a reviewer, I want an abandoned Candidate Session to change nothing on disk, so that a failed load is harmless.
31. As a maintainer, I want the fingerprint to be a pure function of the parsed File, so that fixtures prove its behavior.
32. As a maintainer, I want a narrow `FileReadStore` seam with an in-memory fake, so that Presentation tests need no SQLite.
33. As a maintainer, I want a forward `PRAGMA user_version` migration, so that existing databases upgrade in place.

## Glossary changes

The Review, Presentation, and Diff glossaries already name the main concepts.
M22 sharpens these entries.

- File Review Fingerprint, in the [Review glossary](../../src/review/GLOSSARY.md):
  Replace "canonical old/new diff content" with the exact basis.
  The fingerprint covers the old and new paths, the change kind, the side availability, and each Hunk's Lines.
  It excludes the Hunk header, so `@@` line numbers do not participate.
  A binary File adds the `index` blob ids from its diff header.
  A binary File without those ids has no fingerprint, so it is unverifiable.
- File Read Receipt, in the Review glossary:
  Add that the store holds one receipt for each ReviewIdentity and canonical path.
  The canonical path is the new path when present, otherwise the old path.
  A mark replaces the receipt.
  Candidate Session preparation only reads receipts and never deletes a stale receipt.
- File Read State, in the [Presentation glossary](../../src/tui/GLOSSARY.md):
  Add that a Directory row is bold while any descendant File is unread.
  Add that an unverifiable File is always unread.
- File, in the [Diff glossary](../../src/diff/GLOSSARY.md):
  Add that a File can carry the old and new blob ids from its `index` diff header.
- The Review to Presentation relationship in [GLOSSARY-MAP.md](../../GLOSSARY-MAP.md) stays correct.
  Do not change it.

No new glossary term is necessary.
`FileReadStore` is a seam, so [Code navigation](../../docs/code-navigation.md) names it, not a glossary.

## Behavior

### File Review Fingerprint

`bbr.review.file_read.fingerprint(file: bbr.diff.File) ?FileReviewFingerprint` computes the fingerprint.
It is a pure function of the parsed File.
It returns null when the File is unverifiable.

The function hashes a version-tagged, length-prefixed encoding with SHA-256 from `std.crypto.hash.sha2.Sha256`.
The encoding has these parts, in this order:

1. The encoding version, `1`.
2. `File.old_path` and `File.new_path`.
3. The `File.status` tag, which is the change kind.
4. The side availability of each side: absent, text, binary, or unavailable.
   The function reads only the tag of `File.content.old` and `File.content.new`, never a byte size.
5. For a File with a binary side, the old and new blob ids from `File.blob_ids`.
6. For each Hunk, a Hunk marker, then each Line as its `LineKind` tag and its text.

The encoding excludes `Hunk.header`, `Hunk.old_start`, `Hunk.new_start`, and every Line number.
A pure line shift therefore keeps the fingerprint.
A change to any Line text, Line kind, or Hunk boundary changes the fingerprint.

A File with a binary side and no `File.blob_ids` is unverifiable.

A text File does not use the blob ids.
Its Hunk Lines already describe the review-visible change.

Presentation computes each fingerprint once, during Candidate Session preparation.
This happens before File Enrichment refines `File.content`.
Presentation never computes a fingerprint again from refined File Content Status.

### Blob ids from the diff header

`bbr.diff.parser.parse` reads the `index <old>..<new>` preamble line for every File.
It stores the two ids as `File.blob_ids: ?BlobIds`, borrowed from the raw diff like the paths.
An optional mode after the ids is not part of the ids.
A File without an `index` line has `blob_ids = null`.

`git diff` abbreviates ids by `core.abbrev`.
`ShellGitClient.diff` in `src/git/client.zig` adds `--full-index`, so a LocalReview always gets full ids.

Bitbucket controls the id length of a RemoteReview RawDiff.
The fingerprint hashes the ids as Bitbucket sends them.
A change in Bitbucket's id length makes a binary File unread once.
This failure is conservative, so M22 accepts it.

### File Read Receipt and the FileReadStore

A File Read Receipt is a `bbr.review.FileReadReceipt` with a canonical path and a `FileReviewFingerprint`.
The canonical path is `File.displayPath()`.

`bbr.review.FileReadStore` is a ptr-and-vtable seam, like `PendingReviewStore`.
It has three operations:

- `load(allocator, identity: ReviewIdentity) ![]FileReadReceipt` returns every receipt of one ReviewIdentity.
  It copies every path into `allocator`.
- `put(identity, path, fingerprint) !void` inserts the receipt or replaces the receipt for the same identity and path.
- `delete(identity, path) !void` removes the receipt for that identity and path.
  A missing receipt is not an error.

`bbr.review.InMemoryFileReadStore` is the fake.
It can be set to fail `load`, `put`, or `delete`, so tests can prove the failure paths.
It counts writes, so tests can prove that Candidate Session preparation never writes.

`SqliteStore.fileReadStore()` in `src/persist/sqlite_store.zig` is the production adapter.
It shares the database connection with `SqliteStore.store()`.

### Candidate Session preparation

`Published.createInputs` in `src/tui/presentation.zig` prepares the File Read State of a Candidate Session.
It runs after the PendingReview load and before the initial Buffer and File Tree builds.

1. It computes the fingerprint of each File in `session.diff.files`.
2. It calls `FileReadStore.load` once for the candidate's ReviewIdentity.
3. It marks a File read only when a receipt has the same canonical path and the same fingerprint.
4. A missing receipt, a different fingerprint, or a null fingerprint makes the File unread.

Candidate Session preparation never calls `put` or `delete`.
A stale receipt stays in the store until the next mark of that path replaces it.
An abandoned Candidate Session therefore changes nothing on disk.

A `load` failure does not fail the Candidate Session.
Every File is unread, and publication shows the `file_read_load_failed` status message.
An `error.OutOfMemory` from `load` still fails the candidate, like every other allocation failure.

The same path runs for the initial load, `R`, a PullRequest switch, Reconciliation, and a LocalReview Ref refresh.
The ReviewIdentity has no commit hash, so receipts carry across new SourceCommits.

### File Tree

`file_tree.Entry` gets an `unread: bool` field.
`file_tree.build` takes the read state of each File, index-aligned with `diff.files`.

- A File entry is unread when its File Read State is unread.
- A Directory entry is unread when any descendant File is unread.
  This includes descendants of a collapsed Directory.
- A Directory row shows no count and gets no new layout.

`drawFileTree` in `src/tui/render.zig` sets the bold attribute of every cell in the row from `Entry.unread`.
The row style keeps its foreground and background colors.
This applies to the cursor row and the active row too.
So the `bold = true` in `Theme.sidebar_selected` no longer decides the weight of a File Tree row.

Presentation passes the read state as data.
It does not import vaxis or `theme.zig` for this.

### The toggle_file_read Action

`Action.toggle_file_read` is a new Action in `src/tui/action.zig`.
Its default binding in `src/tui/keymap.zig` is `m`, with the help text "toggle File read".
A `[keymap]` override can rebind or unbind it by the exact name `toggle_file_read`.

`supportsContext` accepts it in `.sidebar_file` and `.diff`.
The DiffPane contexts `.diff_source`, `.diff_disclosure`, and `.diff_review_card` inherit it from `.diff`.
It is not available in `.sidebar_directory` or `.sidebar`.

The Command Palette in `src/tui/list_overlay.zig` lists it with the title "Toggle File Read".
Its description is "Mark the current File read or unread".

The focused File is the File of the Sidebar cursor entry in the Sidebar.
In the DiffPane, it is `Published.activeFile()`.
When the DiffPane cursor has no File, ActionAvailability refuses the Action with `target_action_unavailable`.

`Published.toggleFileRead(file_index)` in `src/tui/presentation.zig` runs the toggle:

1. It refuses an unverifiable File with `file_read_unverifiable`, and it changes nothing.
2. It stages the new File Tree projection with the opposite read state.
3. It persists the change.
   A mark calls `FileReadStore.put` with the File's fingerprint.
   An unmark calls `FileReadStore.delete`.
4. On success, it publishes the staged projection and the new File Read State through an infallible step.
5. On a persistence failure, it discards the staged projection and reports `file_read_save_failed`.
   The File keeps its previous weight.
6. On an allocation failure in step 2, it preserves the previous Presentation Frame and writes nothing.

The toggle does not move the cursor and does not start a File Jump.
When `Dependencies.file_reads` is null, the Action reports `file_read_save_failed` and changes nothing.

### Status messages

M22 adds three `ActionError` values in `src/tui/presentation.zig`.
`actionErrorText` in `src/tui/app.zig` gives each one its text.

- `file_read_save_failed`: "File read state not saved".
- `file_read_load_failed`: "File read state unavailable, all Files show unread".
- `file_read_unverifiable`: "File cannot be verified, so it stays unread".

The status paints them through the existing `Theme.statusStyle` parts.

## Data and persistence model

### Published state

`Published` gets `file_reads: []FileReadEntry`, index-aligned with `session.diff.files`.
It lives in `Published.review_arena`.

```zig
const FileReadEntry = struct {
    fingerprint: ?bbr.review.FileReviewFingerprint,
    read: bool,
};
```

`FileReviewFingerprint` is a struct with one `[32]u8` field.
File Read State is derived from this entry and is never persisted as a bare boolean.

`Dependencies` gets `file_reads: ?bbr.review.FileReadStore = null`.
`src/tui/app.zig` passes `SqliteStore.fileReadStore()` for real and demo runs.
Tests that do not set it see every File unread and no warning.

### SQLite schema

`SqliteStore.migrate` adds version 10 in one transaction:

```sql
CREATE TABLE file_read_receipts (
  review_kind   INTEGER NOT NULL,
  workspace     TEXT NOT NULL,
  repository    TEXT NOT NULL,
  pr_id         INTEGER NOT NULL,
  repository_id INTEGER NOT NULL,
  base_ref      TEXT NOT NULL,
  source_ref    TEXT NOT NULL,
  path          TEXT NOT NULL,
  fingerprint   BLOB NOT NULL,
  PRIMARY KEY (review_kind, workspace, repository, pr_id,
               repository_id, base_ref, source_ref, path)
) WITHOUT ROWID;
PRAGMA user_version = 10;
```

`review_kind` is `0` for a RemoteReview and `1` for a LocalReview.
A RemoteReview row stores its Workspace, Repository, and PullRequestId, with `0` and empty text in the local columns.
A LocalReview row stores its ReviewRepositoryId, BaseRef, and SourceRef, with `0` and empty text in the remote columns.
The table has no reference to `drafts` or any other PendingReview table.

`put` uses `INSERT OR REPLACE`.
`delete` is one keyed `DELETE`.
`load` is one `SELECT` over the identity columns.
A `fingerprint` that is not 32 bytes long makes its receipt absent, so the File is unread.

The store stays on the main thread, like the PendingReviewStore.
The database stays at `$XDG_STATE_HOME/bbr/pending.db`.
M22 adds no new path and no new XDG read.

## Affected modules

| Module | Change |
| --- | --- |
| `src/diff/model.zig` | Add `BlobIds` and `File.blob_ids`. |
| `src/diff/parser.zig` | Read the `index` preamble line into `File.blob_ids`. |
| `src/git/client.zig` | Add `--full-index` to `ShellGitClient.diff`. |
| `src/review/file_read.zig` (new) | `FileReviewFingerprint`, `fingerprint`, `FileReadReceipt`, `FileReadStore`, and `InMemoryFileReadStore`. |
| `src/root.zig` | Export the new `bbr.review` names. |
| `src/persist/sqlite_store.zig` | Migration to version 10 and `SqliteStore.fileReadStore()`. |
| `src/tui/presentation.zig` | `Dependencies.file_reads`, `Published.file_reads`, receipt load in `Published.createInputs`, `Published.toggleFileRead`, and three `ActionError` values. |
| `src/tui/file_tree.zig` | `Entry.unread`, File and Directory read state in `build`. |
| `src/tui/render.zig` | Row weight in `drawFileTree`. |
| `src/tui/action.zig`, `src/tui/keymap.zig` | `toggle_file_read`, its `m` binding, and its contexts. |
| `src/tui/list_overlay.zig` | The Command Palette entry. |
| `src/tui/app.zig` | Wire `Dependencies.file_reads` and the `actionErrorText` texts. |
| `build.zig` | A `test-file-read` target with the filter `M22 read`. |
| Glossaries, `docs/code-navigation.md`, `README.md`, `AGENTS.md`, `TODO.md` | Documentation changes in ticket 04. |

## AGENTS.md rules

M22 touches these existing rules:

- "`presentation.zig` does not import vaxis or `theme.zig`."
  Presentation passes `Entry.unread` as data.
  Only `render.zig` turns it into a bold attribute.
- "The status paints each part through `Theme.statusStyle`."
  The three new messages use existing status parts.
  A new part, if any, must be one arm of `StatusPart`.
- "A terminal surface is a View tree in `src/tui/layouts.zig`."
  The File Tree stays a content painter in the Sidebar Slot.
  The weight change adds no border, rule, or junction glyph.
- "Only `src/xdg.zig` reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`."
  Receipts use the existing `pending.db` path, so no new XDG read happens.
- The Command Palette `comptime` block in `src/tui/list_overlay.zig` must accept the new entry.
  The Action must not be a Motion, and a Pane context must support it.
- "A File Jump calls `Published.jumpToFileHeader`."
  The toggle is not a File Jump and does not move the cursor.

M22 adds two rules to the table in ticket 04:

| Rule | Enforcement |
| --- | --- |
| Candidate Session preparation only reads File Read Receipts. Only `Published.toggleFileRead` writes or deletes them. | The test "M22 read Candidate Session preparation never writes File Read Receipts" in `src/tui/presentation.zig`. |
| The weight of a File Tree row follows File Read State on every row, including the cursor and active rows. | The test "M22 read the File Tree weight follows File Read State on every row" in `src/tui/render.zig`. |

## Testing Decisions

A good test asserts behavior that the reviewer or the store can observe.
Tests assert fingerprint equality, stored receipts, published File Read State, refusals, and rendered cell attributes.
Tests do not assert the encoding bytes, the hash input layout, or private helper calls.

Every new test name starts with `M22 read`, so `zig build test-file-read` runs them.

### Seams

- The pure fingerprint function is the logic seam.
  Fixtures parse unified diff text with `bbr.diff.parser.parse` and compare fingerprints.
- `FileReadStore` is the persistence seam.
  Presentation tests use `InMemoryFileReadStore`.
  Store tests run the same cases against `InMemoryFileReadStore` and `SqliteStore` on `":memory:"`.
- The Presentation transition is the integration seam, as in ADR-0012.
  Tests dispatch Actions and Session replacements and inspect the published Projection.
- Headless rendering is the secondary seam for cell attributes.

### Prior art

- Parser tests in `src/diff/parser.zig`, such as "Git binary stubs classify present File sides without Lines".
- Store tests in `src/review/store.zig` and `src/persist/sqlite_store.zig`, including the v7 and v9 migration tests.
- Presentation tests for Session replacement, failed Draft persistence, and allocation rollback in `src/tui/presentation.zig`.
- Render tests for the File Tree in `src/tui/render.zig`.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.
- The shell Git client test "shell client resolves refs and acquires committed review material" in `src/git/client.zig`.

### Test plan

Fingerprint fixtures:

- The same diff text parsed twice gives equal fingerprints.
- A diff with the same Hunks at other `@@` line numbers gives an equal fingerprint.
- A different Hunk header section text gives an equal fingerprint.
- One changed added, removed, or context Line gives a different fingerprint.
- A changed Hunk boundary with the same Lines gives a different fingerprint.
- A changed old path or new path gives a different fingerprint.
- A changed change kind gives a different fingerprint.
- An added File, a removed File, and a pure rename each have a fingerprint.
- A binary File with `index` ids has a fingerprint, and a changed id changes it.
- A binary File without an `index` line has no fingerprint.
- A refined `File.content` byte size does not change the fingerprint.

Parser and Git:

- The parser reads short and full `index` ids, with and without a trailing mode.
- A File without an `index` line has `blob_ids = null`.
- `ShellGitClient.diff` gives full 40-character ids in a real repository with a binary File.

Store round trips, against both stores:

- `put` then `load` returns the receipt.
- A second `put` for the same identity and path replaces the fingerprint.
- `delete` removes the receipt, and `delete` of a missing receipt succeeds.
- Receipts stay apart for two Repositories with the same PullRequestId.
- Receipts stay apart for a RemoteReview and a LocalReview.
- Receipts stay apart for two LocalReviews with other BaseRefs or SourceRefs.
- A version 9 database migrates to version 10 and keeps its Drafts.
- A version 10 database reopens without a second migration.

Presentation:

- An initial Session with no receipts shows every File unread.
- `m` on a File row in the Sidebar marks the File read and stores one receipt.
- `m` in the DiffPane marks the active File read.
- `m` on a read File deletes the receipt and shows the File unread.
- A failing `put` keeps the File unread and reports `file_read_save_failed`.
- A failing `delete` keeps the File read and reports `file_read_save_failed`.
- An allocation failure while staging the toggle preserves the previous Frame and writes nothing.
- `m` on an unverifiable binary File reports `file_read_unverifiable` and writes nothing.
- `m` on a DiffPane row without a File is refused.
- An unchanged refresh keeps every read File read.
- A refresh where one File changes makes only that File unread.
- A refresh where all Hunks shift keeps every File read.
- A rename, a removal, and a binary blob change each make the File unread.
- A failing `load` publishes every File unread with `file_read_load_failed`.
- Candidate Session preparation never writes, even with stale receipts.
- A superseded Candidate Session writes nothing.
- A PullRequest switch and a switch back restore the read state.
- A LocalReview Ref refresh to a new SourceRef commit keeps unchanged Files read.
- Two Reviews with equal paths do not share read state.
- A Directory entry is unread while any descendant File is unread, also when collapsed.

Rendering:

- An unread File row and an unread Directory row paint bold cells.
- A read File row paints regular cells, also on the cursor row and the active row, in every built-in Theme.

Keymap and Command Palette:

- `m` resolves to `toggle_file_read` in `.sidebar_file` and every DiffPane context.
- `m` resolves to nothing in `.sidebar_directory`.
- A `[keymap]` override can rebind and unbind `toggle_file_read`.
- The Command Palette lists "Toggle File Read" from the Sidebar and the DiffPane.

### Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`, and the reported test count increases.
- `python3 tools/check_agent_docs.py`

The live outside check in ticket 05 is a manual acceptance step.
It does not gate the hermetic suite.

## Implementation tickets

1. [Mark text Files read across Session replacement](issues/01-mark-text-files-read-across-session-replacement.md)
2. [Keep binary Files honest with blob ids](issues/02-keep-binary-files-honest-with-blob-ids.md)
3. [Show Directory progress and survive receipt-load failure](issues/03-show-directory-progress-and-survive-receipt-load-failure.md)
4. [Document M22 and verify the integrated suite](issues/04-document-m22-and-verify-the-integrated-suite.md)
5. [Run the live M22 outside check](issues/05-run-the-live-m22-outside-check.md)

## Out of Scope

- Synchronization of read state with Bitbucket or the GitHub "Viewed" API.
- A count or a progress bar on Directory rows or in the status.
- A bulk Action that marks a Directory or the whole Review read.
- Automatic marking when the reviewer scrolls past a File.
- Cleanup of stale receipts during Candidate Session preparation.
- A garbage-collection command for receipts of closed PullRequests.
- Live updates between two bbr processes on the same Review.
- Normalization of RemoteReview blob id length.
- Changes to Comment, Draft, or Submission behavior.

## Further Notes

- Decision 3 of the brief replaces the TODO line "discard stale receipts for changed or no-longer-participating Files".
  Ticket 04 updates TODO.md to match.
- The receipt load is synchronous on the main thread, like the PendingReview load in `Published.createInputs`.
  So a mark always completes before the next Candidate Session reads receipts.
- The fingerprint covers the parsed diff, not the full File content.
  A change outside the diff context, such as a destination change far from a Hunk, does not reset a File.
  This matches decision 1 of the brief and the GitHub "Viewed" model.
- ADR-0003 holds: the pure `bbr` module owns the seam and the fake, and only `src/persist` uses SQLite.
- ADR-0012 holds: the toggle stages, persists, and then publishes, like `Published.saveDraft`.
