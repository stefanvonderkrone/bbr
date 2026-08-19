# 10 — Project the Submission dependency tree

**What to build:** Replace the status-only Submission result with one live dependency-tree Overlay that follows the authorized Draft forest from queued work through terminal outcomes. Reviewers can inspect why each item posted, failed, skipped, or became outcome unknown, repair a selected failure, and retry only its Reply-descendant subtree.

**Blocked by:** 03 — Edit Draft bodies atomically; 04 — Re-anchor inline root Drafts; 05 — Delete Draft subtrees atomically; 09 — Persist bounded Submission retries.

**Status:** ready-for-human

- [x] One Overlay presents the frozen topological forest with typed TempId, body summary, root scope or Reply parent context, and explicit text for every item state.
- [x] Progress distinguishes queued, posting, waiting to retry, checking publication, persisting, posted, failed, skipped, and outcome unknown without relying on color or glyph alone.
- [x] Selected-row detail shows the complete classified reason, attempt and delay metadata, direct parent dependency, nearest blocking ancestor, and Reply-descendant impact.
- [x] A nonterminal Overlay cannot be dismissed as cancellation; clean and partial terminal results remain inspectable until explicitly dismissed.
- [x] Posted rows are never retryable; skipped Replies point to their blocking ancestor rather than offering an independent retry.
- [x] Confirmed failed rows expose the established edit, root re-anchor, and delete interactions, and returning from repair reconstructs the tree while retaining logical selection where possible.
- [x] Retry selected subtree previews and authorizes exactly the selected eligible Draft plus transitive Reply descendants; unrelated roots, ancestors, siblings, and published items are excluded, and no retry-all Action exists.
- [x] Switching Reviews removes the blocking Overlay without cancelling the PullRequest-qualified Durable Operation; returning reconstructs current progress or the terminal tree from durable state.
- [x] Static wait detail shows local, server, and effective delays without countdown ticks or wall-clock state.
- [x] Deterministic Presentation tests cover complete progress, continue/skip/abort behavior, parent-before-Reply ordering, checkpoint-before-next-POST, selected-subtree isolation, repair return, Session replacement, and clean/partial terminal projection.
