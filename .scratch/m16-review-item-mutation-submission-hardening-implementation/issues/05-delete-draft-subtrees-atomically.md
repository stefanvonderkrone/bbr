# 05 — Delete Draft subtrees atomically

**What to build:** Let a reviewer press `D` on a local Draft, inspect the complete Reply-descendant consequence, and delete the selected Draft subtree as one durable operation. No ambiguous or run-owned evidence may disappear through a partial cascade.

**Blocked by:** 03 — Edit Draft bodies atomically.

**Status:** done

- [x] Delete opens a keyboard-complete confirmation naming the local TempId and complete Draft Reply-descendant count.
- [x] Confirming deletion atomically removes the selected Draft and every transitive descendant reached through Draft parentage.
- [x] The complete deletion is refused when the selected Draft or any descendant participates in an active or recovered SubmissionRun or has an immutable DraftState.
- [x] The store atomically rechecks ReviewIdentity, graph closure, expected parentage, eligibility, and the complete cascade before committing.
- [x] Stage, persist, publish removes PendingReview nodes, ScopeProjection entries, ReviewCard rows, and counts only after durable success.
- [x] Allocation, Buffer, concurrent-state, or persistence failure preserves the old complete Frame and keeps the confirmation available for retry.
- [x] Success selects the next surviving semantic row with previous or nearest-source fallback and remains deleted after refresh, switching, restart, and Session replacement.
- [x] Deterministic tests cover leaf and root deletion, deep descendants, immutable-subtree refusal, atomic rollback, interaction retention, navigation fallback, and in-memory/SQLite parity.
