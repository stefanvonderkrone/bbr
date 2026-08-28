# 15 — Apply File Content Status to LocalReview

**What to build:** Apply the shared File Content Status and UTF-8 contract to Git content so LocalReview and remote review produce the same visible outcomes and ownership guarantees.

**Blocked by:** 12 — Add File Content Status and Status Placeholders.

**Status:** done

- [x] Git content uses the same text, binary, and unavailable states, byte-size rules, and typed reasons as remote File Enrichment.
- [x] Invalid UTF-8 prevents Highlighting and makes only the affected side unavailable while the opposite side remains usable.
- [x] Added, removed, modified, and renamed Files request only their expected sides from the correct commits and paths.
- [x] Highlighting failure preserves readable text, while acquisition failure produces a Status Placeholder.
- [x] `OutOfMemory` transfers neither pending side and leaves the published Session ownership consistent.
