# 12 — Add Authored Review Search

**What to build:** A reviewer can press `g f` to fuzzy-search every authored Comment, Reply, and Draft body in the current Review. The responsive Review Search Overlay supports Preview, keyboard and pointer input, retained state, and exact ReviewCard opening before source acquisition completes.

**Blocked by:** 11 — Add Buffer Search.

**Status:** resolved

- [x] A configurable Action opens Review Search from every DiffPane Interaction Context with `g f` by default. The Overlay captures the complete input surface while open.
- [x] The corpus includes Review-, File-, and inline-scoped Comments, Replies, and Drafts, including resolved, outdated, unavailable, and collapsed items. It excludes Deleted Comments and generated Presentation text.
- [x] ReviewBody scanning starts before File acquisition completes. An empty Query emits no Search Occurrences but still shows the available Candidate count.
- [x] Query input uses the shared Unicode editing rules. Digits enter Query text, and Review Search does not consume Count.
- [x] Fuzzy results globally follow score, Candidate length, and canonical corpus order. Selection survives reorder by Search Occurrence identity and otherwise stays at its prior clamped list position.
- [x] Each result row shows Position without matched text. Kind and Source appear in the selected Preview header, separated from the body by a border line.
- [x] Authored Preview shows the owner, CommentScope, surrounding logical body lines, and every matched range.
- [x] Review Search uses a centered, bordered Overlay at 80% of terminal width and height. It has a 64-column and 14-row minimum, limited by the terminal size.
- [x] The top section contains the Query input. Its bottom border shows the selected match, total matches, Candidate count, and scan state.
- [x] Results and Preview have titled borders. Results occupy 30% of the content width beside Preview; when terminal height exceeds width, Results occupy 30% of the content height above Preview. Each region scrolls independently.
- [x] Long paths shorten each directory to its first character, then drop leading directories if needed. The filename remains visible when the available width permits it.
- [x] Down, Up, `ctrl-n`, and `ctrl-p` select with wraparound. A primary click selects, a primary double-click opens, and the wheel scrolls the region under the pointer.
- [x] Escape closes the Overlay without clearing its Query, selection, list scroll, Preview scroll, Search Occurrences, or DiffPane highlights. Reopening restores that state.
- [x] Buffer Search and Review Search keep separate Session-scoped state. Only the active search paints highlights, and closed Review Search highlights remain active.
- [x] Opening an authored Search Occurrence resolves its current CommentId or TempId, applies its CommentScope, opens the full disclosure chain, and focuses the exact ReviewBody logical line.
- [x] Review-level opening leaves File isolation. File-level and inline opening focus the owning File. Current or moved inline opening selects the resolved Anchor version.
- [x] Outdated or unavailable authored opening preserves Selected Version. Reply and Draft opening inherits the root CommentScope.
- [x] Rendering reads one immutable Review Search projection and uses exact Frame-owned pointer targets. Stale pointer targets cannot change selection or navigation.
- [x] Presentation and headless rendering tests cover authored ranking, Overlay geometry, Preview, input, pointer parity, retained state, exact opening, search ownership, and allocation rollback.

## Comments

Authored Review Search was implemented in `fa8fa78`. The updated Overlay layout was committed in `acd70d4`. Issue 13 tracks source Search Occurrences.
