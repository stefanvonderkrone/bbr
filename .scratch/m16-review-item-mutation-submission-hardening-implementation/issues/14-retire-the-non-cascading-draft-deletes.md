# 14 — Retire the non-cascading Draft deletes

**What to build:** Remove or narrow the two delete paths that predate Draft subtree deletion and can still strand a Reply, so the cascading path is the only way a Draft leaves the graph.

**Blocked by:** 05 — Delete Draft subtrees atomically.

**Status:** done

## Why

Ticket 05 established that a Draft subtree is the only unit deletion works in: a parent link, not a copied scope, places a Reply, so removing a Draft without its descendants strands them. `deleteDraftSubtree` enforces that in both store adapters.

Two older paths still delete without that rule, and neither has a production caller:

- `PendingReviewStore.remove` (`src/review/store.zig`) — on the seam's **vtable**, so every adapter implements it and any future caller gets a single-row delete that silently strands Replies. Called only from `src/review/store.zig` and `src/persist/sqlite_store.zig` tests.
- `PendingReview.remove` (`src/review/draft.zig`) — an in-memory cascade that now duplicates `collectCascade` + `deleteDraftSubtree`, and reports out-of-memory by returning `0` rather than failing. Called only from its own test, `remove takes a draft's reply-descendants with it`.

The hazard is the vtable one: it is a documented, implemented, seam-level operation whose contract contradicts the Draft subtree entry in `src/review/CONTEXT.md`. Dead code is not the problem — a reachable delete with the wrong semantics is.

## Decisions to make while implementing

- `PendingReviewStore.remove` is deleted entirely. It had no production caller, and removing it shrinks the vtable so future adapters cannot accidentally expose a non-cascading delete.
- The missing-id behavior is intentionally not preserved: `deleteDraftSubtree` remains non-idempotent and returns `DraftNotFound`, matching reviewer-confirmed deletion rather than cleanup semantics. Existing adapter tests cover that contract.
- `PendingReview.remove` is deleted entirely. The in-memory model has no independent deletion caller, and its silent `0`-on-OOM result was not an honest mutation contract.

## Acceptance

- [x] No delete path reachable through `PendingReviewStore` can remove a Draft while leaving a Draft that reaches it through parentage.
- [x] The surviving `deleteDraftSubtree` contract is documented, and `src/review/CONTEXT.md`'s Draft subtree entry matches the implemented rule.
- [x] Removing the vtable method leaves both adapters and every seam consumer compiling, with no behaviour change to submission, recovery, or resolution paths.
- [x] Tests that only exercised the retired paths were deleted rather than retargeted; verification reports 552/552 tests passed.
- [x] Deterministic adapter tests cover the surviving contract, including `DraftNotFound` for a missing confirmed root rather than idempotent deletion.
