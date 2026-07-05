# Pending reviews are batched client-side

Bitbucket **Cloud** has no native draft/pending-review concept — a POST to the comments
endpoint publishes immediately (unlike GitHub, or Bitbucket Data Center). We therefore
implement the "hold comments until I submit them together" workflow entirely in the client:
Drafts live in a local PendingReview (persisted to SQLite) and are published as a batch on
Submission.

## Consequences

- Submission is our responsibility, including **topological ordering** (parents before
  replies, since a reply needs its parent's server-assigned id) and temp-id → server-id remapping.
- There is no server transaction, so we cannot roll back a partial batch. Policy: retry
  transient/429/5xx, **stop the batch on auth failure**, mark-and-continue on per-item
  validation failure, and guard against duplicate posts (ambiguous network failure) with a
  GET-and-dedupe check before re-POSTing.
- "Applying" a suggestion is out of scope — Cloud exposes no apply-suggestion endpoint;
  we author the fenced ```suggestion``` block and the reviewer applies it in the web UI.
