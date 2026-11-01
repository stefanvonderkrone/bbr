# 04: Document M22 and verify the integrated suite

Status: resolved
Blocked by: 02, 03
Spec: [M22 spec](../SPEC.md)

## What to build

The glossaries, the agent documents, and the README describe the shipped M22 behavior.
The integrated hermetic suite passes with every M22 test.

## Scope

- Apply the glossary changes from the "Glossary changes" section of the spec.
  Edit the Review, Presentation, and Diff glossaries.
- Add the `FileReadStore` seam to the "Seams" list in `docs/code-navigation.md`.
- Add the two M22 rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
  Make sure that each named test exists with that exact name.
- Describe `m`, `toggle_file_read`, bold unread Files, and bold Directory rows in `README.md`.
  State that read state stays local and never goes to Bitbucket.
- In the M22 section of `TODO.md`, replace "discard stale receipts for changed or no-longer-participating Files".
  The new text states that preparation only reads receipts and that the next mark replaces a stale receipt.
- Check each M22 TODO line that the evidence proves.
- Run the integrated checks and record the results under `## Completion` in this ticket.

## Acceptance criteria

- [x] The glossary entries match the spec and use the glossary terms exactly.
- [x] `docs/code-navigation.md` names `FileReadStore`, its SQLite adapter, and its in-memory fake.
- [x] `AGENTS.md` has the two M22 rules, and each named test exists.
- [x] `README.md` documents the `m` binding, the Action name, and the local-only storage.
- [x] `TODO.md` matches decision 3 of the brief.
- [x] `python3 tools/check_agent_docs.py` passes.
- [x] `zig fmt --check build.zig src`, `zig build`, and `zig build test-file-read` pass.
- [x] `zig build test --summary all` passes, and the reported test count is higher than before M22.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`

## Completion

The Review glossary gives the exact basis of the File Review Fingerprint.
It also states that the store holds one File Read Receipt for each ReviewIdentity and canonical path.
The Presentation glossary adds the bold Directory row and the unverifiable File to File Read State.
The Diff glossary adds the `index` blob ids to File.
`GLOSSARY-MAP.md` is unchanged.

`docs/code-navigation.md` names the `FileReadStore` seam, `SqliteStore.fileReadStore()`, and `InMemoryFileReadStore`.
`AGENTS.md` has the two M22 rules.
Both named tests exist with those exact names.
`Published.toggleFileRead` holds the only `put` and `delete` call on a `FileReadStore` in `src/tui/presentation.zig`.
No other `AGENTS.md` rule needed a change.

`README.md` documents `m`, `toggle_file_read`, bold unread Files, bold Directory rows, and the failure messages.
It states that File Read Receipts persist in `pending.db` and never go to Bitbucket.

`TODO.md` now states that preparation only reads receipts and that the next mark replaces a stale receipt.
I checked all seven M22 lines.
The last M22 line asks for Presentation coverage of the rename and removal cases.
The test "M22 read a refresh with a rename or a removal makes that File unread" in `src/tui/presentation.zig` gives this coverage.
It marks three Files read and refreshes with a renamed File, a removed File, and an unchanged File.
After publication, the renamed File and the removed File are unread, and the unchanged File stays read.
The refresh writes no File Read Receipt.
Two mutations make this test fail.
The first mutation marks a File read when a receipt has its path, without a fingerprint compare.
The second mutation matches receipts by fingerprint only and removes the paths and the change kind from the fingerprint.
Only the new test catches the second mutation in Presentation.

The ADRs do not contradict M22.
ADR-0003 and ADR-0006 still describe the seam and the SQLite store correctly.

Checks, run in `/Volumes/Work/t3-code/m22-durable-file-read-state`:

- `python3 tools/check_agent_docs.py` passed.
- `zig fmt --check build.zig src tests` passed.
- `zig build` passed.
- `zig build test-file-read --summary all` passed with 50 of 50 tests.
- `zig build test --summary all` passed with 24 of 24 steps and 1423 of 1423 tests.
  The count before M22 was 1378.

## Comments

### Merge with main and review fixes M22-2, M22-5, and M22-6

Merge commit `ecb8606` brings in `origin/main` at `497c86f`.
Main made `keymap.helpSection` an exhaustive switch, so the merge did not compile.
`toggle_file_read` now belongs to the Panes and Files help section, after `focus_file`.
Both Actions act on the File under the cursor, so the help Overlay lists them together.

Two AGENTS.md rows claimed more enforcement than exists.
The `downgradeTo` row now covers only version 7 and later, because `downgrades` cannot make an older database.
The row no longer quotes the compile error message, so the M30 test-name check does not misread it.
The use of `downgradeTo` in a new migration test is a convention.
The single receipt writer `Published.toggleFileRead` is also a convention.
Both rows now say "convention (no check)" for those parts.

After the fixes, `zig build test --summary all` passed with 24 of 24 steps and 1465 of 1465 tests.
