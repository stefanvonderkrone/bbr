# 27 — Prefetch One Remote Successor

**What to build:** Hide most sequential remote File Enrichment delay by prefetching only the immediate successor after explicit forward File traversal.

**Blocked by:** 13 — Classify RawDiff Binary Files; 14 — Acquire Remote File Sides Safely.

**Status:** ready-for-agent

- [ ] Explicit navigation to the immediately next Diff File arms one successor after the focused File reaches a terminal File Enrichment state.
- [ ] Initial focus, backward navigation, direct File Tree focus, File finding, mouse focus, jumps, and LocalReview start only demand work and disarm later prefetch.
- [ ] At most one speculative File runs, demand work is never delayed, and focusing the speculative File promotes the same work without a duplicate request.
- [ ] Disabling the inactive File cache disables prefetch, and speculative results use the existing whole-File LRU admission and eviction rules.
- [ ] Speculative failure stays silent until focus, and stale results are rejected through Session Epoch and normal ownership cleanup.
- [ ] Persistence tests prove that prefetch writes no File content or Highlighting data to SQLite, state directories, or data directories.
