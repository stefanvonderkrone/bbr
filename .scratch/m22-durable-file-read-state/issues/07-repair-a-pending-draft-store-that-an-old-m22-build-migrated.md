# 07: Repair a pending Draft store that an old M22 build migrated

Status: needs-triage
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
