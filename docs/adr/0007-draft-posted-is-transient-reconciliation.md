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
- Submission (M10) owns the delete-on-batch-success step; the `PendingReviewStore` already
  supports it via per-Draft `remove`.
- Submission checkpoints each Draft around its network call; it does not POST the whole batch
  and persist all outcomes in one transaction at the end. Before a POST, the Draft's
  `submitting` intent is persisted. Before the next POST, the previous outcome (`posted` with
  its `CommentId`, or `failed`) is persisted. Persisting one outcome and the next intent may
  share a short SQLite transaction, but no database transaction stays open during network I/O.
- A crash after Bitbucket accepts a POST but before its outcome is persisted leaves a
  `submitting` Draft. Resume treats that state as ambiguous and runs the Duplicate guard before
  attempting another POST. This is the unavoidable recovery seam between two systems that
  cannot share a transaction.
