# 14 — Retire the non-cascading Draft deletes

**What to build:** Remove or narrow the two delete paths that predate Draft subtree deletion and can still strand a Reply, so the cascading path is the only way a Draft leaves the graph.

**Blocked by:** 05 — Delete Draft subtrees atomically.

**Status:** ready-for-agent

## Why

Ticket 05 established that a Draft subtree is the only unit deletion works in: a parent link, not a copied scope, places a Reply, so removing a Draft without its descendants strands them. `deleteDraftSubtree` enforces that in both store adapters.

Two older paths still delete without that rule, and neither has a production caller:

- `PendingReviewStore.remove` (`src/review/store.zig:225`) — on the seam's **vtable**, so every adapter implements it and any future caller gets a single-row delete that silently strands Replies. Called only from `src/review/store.zig` and `src/persist/sqlite_store.zig` tests.
- `PendingReview.remove` (`src/review/draft.zig:209`) — an in-memory cascade that now duplicates `collectCascade` + `deleteDraftSubtree`, and reports out-of-memory by returning `0` rather than failing. Called only from its own test at `src/review/draft.zig:403`.

The hazard is the vtable one: it is a documented, implemented, seam-level operation whose contract contradicts the Draft subtree entry in `src/review/CONTEXT.md`. Dead code is not the problem — a reachable delete with the wrong semantics is.

## Decisions to make while implementing

- Whether `remove` goes entirely, or survives narrowed to leaf Drafts with an explicit in-transaction childlessness recheck. Deleting it shrinks the vtable every adapter implements; keeping it needs a caller that actually wants it.
- Whether any later M16 ticket needs `remove`'s **idempotence** on a missing id. `deleteDraftSubtree` returns `DraftNotFound` instead, which is the right answer for a reviewer-confirmed deletion but may be wrong for a cleanup path — check 07, 08, and 11 before choosing.
- Whether `PendingReview.remove` should be deleted or reimplemented on top of `descendsFrom`, given Presentation now computes the closure itself and the silent `0`-on-OOM return has no honest caller.

## Acceptance

- [ ] No delete path reachable through `PendingReviewStore` can remove a Draft while leaving a Draft that reaches it through parentage.
- [ ] Whatever survives states its cascade contract in its doc comment, and `src/review/CONTEXT.md`'s Draft subtree entry matches the implemented rule.
- [ ] Removing a vtable method leaves both adapters and every seam consumer compiling, with no behaviour change to submission, recovery, or resolution paths.
- [ ] Tests that only exercised the retired paths are deleted rather than retargeted, and the per-step test count is confirmed to move as expected.
- [ ] Deterministic tests cover the surviving contract, including the idempotence decision recorded above.
