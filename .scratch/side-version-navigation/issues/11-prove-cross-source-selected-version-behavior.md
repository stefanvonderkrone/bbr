# 11 — Prove cross-source Selected Version behavior

**What to build:** Prove that RemoteReview and LocalReview use one Selected Version contract through the shared Diff, Buffer, and File Enrichment pipeline.

**Blocked by:** 10 — Activate the Selected Version title controls.

**Status:** ready-for-agent

- [ ] Deterministic Presentation tests cross RemoteReview and LocalReview with equal reviewer-visible behavior.
- [ ] Tests cross Unified and SideBySide with Changes, fetched-whole, and WholeFile.
- [ ] Changes and fetched-whole tests prove that version changes affect only the title and source Action target.
- [ ] WholeFile tests cover added, modified, removed, and renamed Files with old and new line numbers and paths.
- [ ] File Enrichment tests preserve one-successor remote prefetch, remote two-side concurrency, and local sequential work.
- [ ] Partial success keeps usable content, and refresh through `R` remains the only retry path.
- [ ] Duplicate, stale Session Epoch, stale WorkId, launch failure, and refresh cases cannot corrupt the Frame or Selected Version.
- [ ] Layout, Scope, successful Session replacement, failed Session replacement, and application restart follow the specified Selected Version lifetime.
- [ ] Tests inspect published state, commands, clipboard text, refusal reasons, and reviewer-visible rows rather than private scheduling details.
