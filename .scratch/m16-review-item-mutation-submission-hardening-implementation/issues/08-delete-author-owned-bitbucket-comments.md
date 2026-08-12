# 08 — Delete author-owned Bitbucket Comments

**What to build:** Let the Authenticated Account press `D` on one of its published Comments or Replies, confirm the remote consequence, and reconcile Bitbucket’s authoritative Thread. Root deletion preserves surviving Replies beneath a visible Deleted Comment tombstone rather than cascading locally.

**Blocked by:** 07 — Edit author-owned Bitbucket Comments.

**Status:** ready-for-agent

- [ ] Delete uses the same UUID ownership, Deleted Comment, identity-evidence, and global remote-write lane rules as published edit.
- [ ] Confirmation names the CommentId and remote effect; for a root with Replies it explains that Bitbucket removes the body while retaining a tombstone and Replies.
- [ ] No local cascade or optimistic graph mutation occurs before Reconciliation.
- [ ] Confirmed success and outcome-unknown transport results start Reconciliation without automatic retry; `404` also starts Reconciliation because the loaded graph is stale.
- [ ] A definitive failure restores the confirmation when its initiating Session remains current; Session replacement closes only the Session-relative Overlay and does not cancel the mutation.
- [ ] Deleted Comment decoding retains CommentId, author, parent relationship, and root CommentScope while removing authored body and mutation availability.
- [ ] Presentation renders `Deleted Comment` with distinct neutral styling and keeps surviving Replies in their real Thread.
- [ ] Failed Reconciliation reports deletion success plus reload-required and gates later remote writes from that stale Session only.
- [ ] Fake-adapter and deterministic Presentation tests cover root and Reply deletion, tombstones, surviving Replies, definitive and unknown outcomes, `404`, lane ownership, Session replacement, and authoritative reload.
