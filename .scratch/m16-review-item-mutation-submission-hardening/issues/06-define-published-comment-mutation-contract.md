# Define the author-owned published Comment mutation contract

Type: grilling
Status: resolved
Blocked by: 01, 04, 13

## Question

Given Bitbucket's verified capabilities, how should authorship-based ActionAvailability, edit and delete commands, failure projection, identity preservation, unsupported re-anchoring, and post-success Reconciliation compose into the published Comment mutation contract satisfying `.scratch/review-item-mutation/issues/02-edit-delete-owned-bitbucket-comments.md`?

## Answer

Published Comment mutation is fail-closed on identity evidence without making review acquisition depend on mutation capability. Load the authenticated account UUID through the Bitbucket boundary and compare it only with each Comment author's UUID. A missing authenticated UUID or missing Comment-author UUID proves no ownership; display name and credential presence are never substitutes. A `401` invalidates this mutation capability until identity is acquired again.

Edit and delete are available for every non-deleted author-owned Comment or Reply, including Comments in resolved Threads, Outdated inline Comments, and Suggestion-bearing Comments. They remain visible but unavailable with an exact reason for another author's Comment, unavailable identity evidence, a Deleted Comment, an immutable published Anchor, or another active published Comment mutation. Replies have no independent Anchor. M16 offers no published re-anchor Action or replacement workflow because Bitbucket rejects Anchor changes.

Editing sends only the accepted Composer bytes as `content.raw` to the selected `CommentId`. It preserves Comment identity, parentage, and CommentScope, and treats Suggestion Markdown as ordinary body content. Deletion requires a remote-effect confirmation. For a root with Replies, confirmation explains that Bitbucket removes the body and retains a Deleted Comment tombstone while the Replies remain; Reconciliation, never a local cascade, determines the final Thread.

Deleted Comments remain in Review as structural tombstones carrying their CommentId, author, parent relationship, and root CommentScope. Presentation renders the tombstone as `Deleted Comment` in a muted neutral grey/slate ReviewCard with no mutation Actions, while surviving Replies retain normal Reply styling.

Only one published Comment mutation may be active globally. The accepted operation carries its Repository-qualified PullRequest identity and `CommentId`, continues across Session replacement, and reports a PullRequest-qualified result if another Session is current. It is in-memory only: ordinary quit drains it, while abrupt process exit causes no startup retry or recovery record; the next PullRequest load observes Bitbucket's authoritative state.

While the initiating Session remains current, edit and delete Overlays become read-only in-progress surfaces. A definitive edit failure restores the editable Composer with the attempted bytes; a definitive delete failure restores confirmation. Session replacement closes the Session-relative Overlay without cancelling the remote request.

There are no automatic retries. A received rejection preserves the published graph and surfaces its classified error. `404` additionally starts Reconciliation because the loaded graph is stale. `429`, server, definite non-delivery, `400`, `403`, and conflict restore the initiating Overlay when its Session remains current. A response-lost transport result is `mutation outcome unknown` and immediately starts Reconciliation rather than claiming failure or repeating the request.

Every confirmed success starts Reconciliation. If confirmed mutation succeeds but Reconciliation fails, close the Overlay, preserve the old complete Session, and report `Bitbucket Comment updated/deleted; Reconciliation failed - refresh required`; `R` retries authoritative loading. Never reinterpret that split result as mutation failure or patch the old graph optimistically.

After an unknown edit outcome, matching authoritative `content.raw` means applied; a different body means not applied or superseded. After an unknown delete outcome, an absent Comment or Deleted Comment means applied; a live Comment means not applied. In every case, publish the complete reconciled Bitbucket graph and do not retry automatically.

Context: [Establish Bitbucket's published Comment mutation contract](01-establish-bitbucket-comment-mutation-contract.md), [Choose the review-item mutation interaction](04-choose-review-item-mutation-interaction.md), and [Live-probe published Comment mutation edge cases](13-live-probe-comment-mutation-edge-cases.md). The Deleted Comment domain term is recorded in `src/review/CONTEXT.md`.
