# 13 — Classify RawDiff Binary Files

**What to build:** Identify binary Files from RawDiff before File Enrichment starts. Show binary Status Placeholders for the applicable sides and keep all source-only interactions disabled.

**Blocked by:** 12 — Add File Content Status and Status Placeholders.

**Status:** done

- [x] RawDiff Git binary stubs classify the present File sides as binary without creating synthetic Lines.
- [x] File Enrichment does not fetch or Highlight a side that RawDiff already classifies as binary.
- [x] Added, removed, modified, and renamed binary Files show the correct independent side placeholders in both Layouts and Scopes.
- [x] Binary placeholders show known byte size or `size unavailable` and cannot become Selection or Anchor targets.
- [x] File-level and Review-level Comments remain visible for binary Files.
