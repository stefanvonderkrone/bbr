# 05 — Delete Draft subtrees atomically

**What to build:** Let a reviewer press `D` on a local Draft, inspect the complete Reply-descendant consequence, and delete the selected Draft subtree as one durable operation. No ambiguous or run-owned evidence may disappear through a partial cascade.

**Blocked by:** 03 — Edit Draft bodies atomically.

**Status:** ready-for-agent

- [ ] Delete opens a keyboard-complete confirmation naming the local TempId and complete Draft Reply-descendant count.
- [ ] Confirming deletion atomically removes the selected Draft and every transitive descendant reached through Draft parentage.
- [ ] The complete deletion is refused when the selected Draft or any descendant participates in an active or recovered SubmissionRun or has an immutable DraftState.
- [ ] The store atomically rechecks ReviewIdentity, graph closure, expected parentage, eligibility, and the complete cascade before committing.
- [ ] Stage, persist, publish removes PendingReview nodes, ScopeProjection entries, ReviewCard rows, and counts only after durable success.
- [ ] Allocation, Buffer, concurrent-state, or persistence failure preserves the old complete Frame and keeps the confirmation available for retry.
- [ ] Success selects the next surviving semantic row with previous or nearest-source fallback and remains deleted after refresh, switching, restart, and Session replacement.
- [ ] Deterministic tests cover leaf and root deletion, deep descendants, immutable-subtree refusal, atomic rollback, interaction retention, navigation fallback, and in-memory/SQLite parity.
