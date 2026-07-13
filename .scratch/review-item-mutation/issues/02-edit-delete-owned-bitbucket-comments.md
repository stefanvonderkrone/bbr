Status: ready-for-agent

# Edit and delete author-owned Bitbucket Comments

## What to build

Let the authenticated reviewer edit or delete their own published Bitbucket Comments, including Replies and Comments containing Suggestions. Begin by verifying the official Bitbucket Cloud operations and authorship fields, then expose only the mutations Bitbucket supports. Bitbucket remains authoritative: after a successful mutation, Reconciliation reloads the PullRequest instead of patching the local Comment graph optimistically.

Published Comment mutation is distinct from Draft mutation. Ownership comes from the authenticated Bitbucket identity, not from the local Session or the fact that a Comment appears in the current review.

## Acceptance criteria

- [ ] Official Bitbucket Cloud documentation or executable adapter fixtures establish the supported update/delete operations and the field used to determine whether the authenticated user owns a Comment.
- [ ] Edit and delete Actions are offered only for a Comment or Reply owned by the authenticated user; they are absent or refused for every other author.
- [ ] Editing preserves the Comment's identity and parent relationship, and supports Suggestion bodies as ordinary Comment content.
- [ ] Deletion requires confirmation and follows Bitbucket's documented root/reply behavior.
- [ ] A successful mutation triggers Reconciliation; a rejected or failed mutation leaves the published Presentation state unchanged and surfaces the classified error.
- [ ] Moving a published inline Anchor is implemented only if Bitbucket Cloud explicitly supports it; otherwise the limitation is documented and no misleading re-anchor Action is shown.
- [ ] Fake-adapter and deterministic Presentation tests cover ownership, edit, delete, unsupported re-anchoring, API failure, and Reconciliation.

## Blocked by

None - capability verification is the first gate within this slice.

## Comments

