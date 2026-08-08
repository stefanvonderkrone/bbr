# Establish Bitbucket's published Comment mutation contract

Type: research
Status: resolved
Blocked by: none

## Question

What do Bitbucket Cloud's primary documentation, API schemas, and executable live behavior establish about identifying the authenticated author and editing or deleting root Comments, Replies, and Suggestion-bearing Comments; what happens to Replies when a root is deleted; and can an existing published inline Comment's Anchor be changed without creating a replacement Comment?

## Answer

Determine authorship by comparing the authenticated account's UUID from `GET /2.0/user` with `comment.user.uuid`; display names are not identities. Author-owned roots and Replies use the same CommentId-addressed update and delete endpoints. Updates should send only `content.raw`, preserve identity and parentage, and treat Suggestion-bearing bodies as ordinary raw Comment content. After any accepted mutation, Reconciliation reloads Bitbucket's authoritative graph rather than applying a local cascade or optimistic patch.

Published inline Anchors have no documented mutation contract and are immutable in bbr. Re-anchoring means authoring a replacement Comment and, if desired, separately deleting the old one; M16 must not send speculative `inline` fields on update.

Primary documentation does not settle PullRequest root deletion when Replies exist, the exact Suggestion raw-body round trip, or whether attempted `inline` updates are rejected or ignored. Those evidence gaps graduate to [Live-probe published Comment mutation edge cases](13-live-probe-comment-mutation-edge-cases.md).

Context: `docs/research/bitbucket-published-comment-mutation.md` on branch `research/bitbucket-published-comment-mutation`, commit `9bca998486724284bd659a82bab8396a618f8a65`.
