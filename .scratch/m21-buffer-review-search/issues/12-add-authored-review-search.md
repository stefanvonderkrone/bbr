# 12 — Add Authored Review Search

**What to build:** A reviewer can press `g f` to fuzzy-search every authored Comment, Reply, and Draft body in the current Review. The responsive Review Search Overlay supports Preview, keyboard and pointer input, retained state, and exact ReviewCard opening before source acquisition completes.

**Blocked by:** 11 — Add Buffer Search.

**Status:** ready-for-agent

- [ ] A configurable Action opens Review Search from every DiffPane Interaction Context with `g f` by default. The Overlay captures the complete input surface while open.
- [ ] The corpus includes Review-, File-, and inline-scoped Comments, Replies, and Drafts, including resolved, outdated, unavailable, and collapsed items. It excludes Deleted Comments and generated Presentation text.
- [ ] ReviewBody scanning starts before File acquisition completes. An empty Query emits no Search Occurrences but still shows the available Candidate count.
- [ ] Query input uses the shared Unicode editing rules. Digits enter Query text, and Review Search does not consume Count.
- [ ] Fuzzy results globally follow score, Candidate length, and canonical corpus order. Selection survives reorder by Search Occurrence identity and otherwise stays at its prior clamped list position.
- [ ] Each result row shows Kind, Source, and Position. Matched text appears in Preview rather than the dense result list.
- [ ] Authored Preview shows the owner, CommentScope, surrounding logical body lines, and every matched range.
- [ ] Landscape geometry places results beside Preview. Portrait geometry places results above Preview. The result list and Preview keep independent scroll state.
- [ ] Down, Up, `ctrl-n`, and `ctrl-p` select with wraparound. A primary click selects, a primary double-click opens, and the wheel scrolls the region under the pointer.
- [ ] Escape closes the Overlay without clearing its Query, selection, list scroll, Preview scroll, Search Occurrences, or DiffPane highlights. Reopening restores that state.
- [ ] Buffer Search and Review Search keep separate Session-scoped state. Only the active search paints highlights, and closed Review Search highlights remain active.
- [ ] Opening an authored Search Occurrence resolves its current CommentId or TempId, applies its CommentScope, opens the full disclosure chain, and focuses the exact ReviewBody logical line.
- [ ] Review-level opening leaves File isolation. File-level and inline opening focus the owning File. Current or moved inline opening selects the resolved Anchor version.
- [ ] Outdated or unavailable authored opening preserves Selected Version. Reply and Draft opening inherits the root CommentScope.
- [ ] Rendering reads one immutable Review Search projection and uses exact Frame-owned pointer targets. Stale pointer targets cannot change selection or navigation.
- [ ] Presentation and headless rendering tests cover authored ranking, Overlay geometry, Preview, input, pointer parity, retained state, exact opening, search ownership, and allocation rollback.
