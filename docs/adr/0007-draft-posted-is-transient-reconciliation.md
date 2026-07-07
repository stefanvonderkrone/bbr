# Draft `posted` state is transient reconciliation, deleted on batch success

A `DraftState` of `posted` carries the server-assigned `CommentId` a Draft received when
Submission POSTed it. This looks like a permanent "this Draft became comment N" record, but it
is **not**: `posted` exists only to reconcile a Submission that was interrupted, and the Draft's
row is **deleted from the PendingReviewStore once the whole batch succeeds**.

## Why not keep posted Drafts

Bitbucket is authoritative for published comments (ADR-0001): once a Draft is POSTed it comes
back on the next fetch as a `Comment`. If the `posted` Draft also lived on in SQLite, the same
logical comment would exist twice — a `posted` Draft *and* a fetched `Comment` — and every
launch would have to dedup them by `CommentId` in the render path. That tax is paid forever, on
data that has a single rightful owner (the server).

## Why keep them *during* a batch

Submission is not atomic across items — it POSTs each Draft in topological order and
continues-on-item-failure. Two things force `posted` to persist until the batch ends:

1. **No double-POST.** If we sent 3 of 5 Drafts and crashed, resume must know those 3 are done.
   Their `posted` rows (with `CommentId`) say so.
2. **Reply remapping.** A reply Draft's parent may be *another Draft* (`Parent.draft`). Before
   the reply can POST, its parent must have a real `CommentId` to remap to `Parent.comment`.
   Keeping the parent's `posted` row until batch-end makes that remap recoverable after a crash.

So the deletion is on **batch** success, not per-item success.

## Consequences

- The invariant "there is exactly one representation of a published comment" holds at rest; the
  double-representation window is confined to an in-progress (or crashed-mid-) Submission.
- The render path needs `CommentId` dedup **only** for that transient window, not on every
  normal launch.
- Submission (M9) owns the delete-on-batch-success step; the `PendingReviewStore` already
  supports it via per-Draft `remove`.
