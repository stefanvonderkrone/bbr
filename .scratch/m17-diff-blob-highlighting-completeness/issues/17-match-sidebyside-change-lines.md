# 17 — Match SideBySide Change Lines

**What to build:** Align related removed and added Lines within each SideBySide change block without changing Diff order, Line identity, or Anchor placement.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Maximal removed-then-added blocks use deterministic order-preserving matching with the specified token-byte similarity, eligibility threshold, pair cost, and gap cost.
- [ ] Equal-cost results prefer exact pairs and then the earliest eligible old and new pair.
- [ ] Insertions and deletions do not offset later related Lines, while unrelated Lines appear opposite an empty side.
- [ ] Repeated and blank Lines remain stable across Buffer rebuilds, and every underlying Line appears exactly once.
- [ ] Only accepted pairs receive IntraLineSegments; Unified Layout and old-side and new-side Comment and Draft placement remain unchanged.
