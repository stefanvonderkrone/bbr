# 14: Find why a real pending Draft store is at version 10 without the posted_drafts table

Status: needs-triage
Blocked by: none

## Summary

This defect comes from `main`. It is not part of the enrichment rebuild cascade.
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
