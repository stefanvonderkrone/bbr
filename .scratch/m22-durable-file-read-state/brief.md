# M22 Durable File read state: brief

Status: ready-for-agent
Milestone: M22

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M22.
The requirements live in the M22 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Review glossary](../../src/review/GLOSSARY.md) and [the Presentation glossary](../../src/tui/GLOSSARY.md).

## In my own words

A reviewer works through a PullRequest File by File.
Today, bbr does not show which Files the reviewer already finished.
After a reload, a PullRequest switch, or a restart, the reviewer must remember their progress.

The goal is a durable, local "I reviewed this File" mark.
The File Tree shows each unfinished File in bold.
The mark must survive reloads, but it must not lie.
When the author pushes a change to a File, only that File becomes bold again.
Files that did not change keep their mark.

The real problem is trust in the mark.
A mark that resets too often is noise, and the reviewer stops using it.
A mark that survives a real change hides new code from review.
The File Review Fingerprint decides between those two failures.

## Expert approach

- Raw sources: the parsed Diff of each File, the `index <old>..<new>` blob ids in each diff header, and the existing SQLite store with its `PRAGMA user_version` migrations.
- Prior art: the GitHub "Viewed" checkbox resets a File when its diff changes after the mark.
  M22 follows the same model.
- Method: the fingerprint is a pure function of the review-visible change.
  Fixtures prove which edits change it and which edits do not.
- Outside check: on a live PullRequest, mark every File read.
  Push one commit that changes one File, and merge the destination branch into the source branch.
  After `R`, only the changed File is bold.
  Repeat on a LocalReview with a new commit on the SourceRef.

## Decisions

The user made these decisions on 2026-10-29.

1. **Fingerprint basis: hunk content without line numbers.**
   Hash the old and new paths, the change kind, the side availability, and each Hunk's context, added, and removed Lines.
   Ignore the `@@` line numbers.
   A pure line shift, such as a destination merge that moves the File, keeps the File read.
2. **Binary Files: use the blob ids from the `index` header.**
   The parser reads `index <old>..<new>` for binary Files and adds the ids to the fingerprint.
   When the header is absent, the fingerprint is unverifiable and the File stays unread.
3. **Stale receipts: keep them, and overwrite on mark.**
   Candidate Session preparation only reads receipts.
   It never writes or deletes.
   A mismatched receipt projects as unread.
   The next mark replaces it.
   The store holds one receipt for each (ReviewIdentity, canonical path).
   This decision replaces the TODO line "discard stale receipts for changed or no-longer-participating Files".
4. **Directory rows: bold while any descendant File is unread.**
   A directory row shows no count and gets no new layout.

## Specification changes

- Loosened: Candidate Session preparation does not delete stale receipts (decision 3).
  A read-only load cannot fail on a write, and an abandoned Candidate Session changes nothing.
- Added: the fingerprint ignores `@@` line numbers (decision 1).
- Added: binary Files use the `index` blob ids (decision 2).
- Added: a LocalReview diff must produce stable blob ids.
  `git diff` abbreviates ids by `core.abbrev`, so the local DiffSource must use `--full-index`, or the fingerprint must not depend on the id length.
- Kept: every other M22 TODO line, including the `m` binding, persist-before-publish, the failed-write fallback, the receipt-load warning, and ReviewIdentity isolation.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the implementation tickets in this directory.
