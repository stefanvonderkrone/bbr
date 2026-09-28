# 14 — Add Exact Source Opening and Harden Search

**What to build:** A reviewer can open any source Search Occurrence at its exact wrapped range, including content that Review Search must reacquire. All search work remains atomic and Session-safe through closure, failure, refresh, Review switching, and shutdown.

**Blocked by:** 13 — Stream Source into Review Search.

**Status:** resolved

- [x] Opening an old or new source Search Occurrence selects that version. Opening a version-neutral occurrence preserves Selected Version.
- [x] Source opening focuses the owning File without forcing File isolation. Existing isolation changes to the owning File, while an all-Files Buffer stays all-Files.
- [x] A source Line in a visible Hunk keeps the current Scope. A source Line outside all Hunks switches to WholeFile.
- [x] Search-owned Fold reveals expose an exact hidden destination without changing the saved Fold state.
- [x] The cursor lands on the first wrapped visual row that contains the first matched range. Every range for the opened occurrence remains highlighted.
- [x] Opening cached content stages File focus, isolation, Selected Version, Scope, disclosures, cursor, scroll, and highlights in one complete Presentation Frame before the Overlay closes.
- [x] Opening evicted content keeps the Overlay open and reacquires the required File Enrichment before navigation.
- [x] Successful reacquisition publishes the exact destination Frame before closing the Overlay. Failure keeps the Overlay, Query, and selection and never opens an approximate Line.
- [x] Review Search highlights reproject after Layout, Scope, isolation, disclosure, or Buffer changes. DiffPane navigation does not clear them.
- [x] Activating Buffer Search restores temporary Review Search Fold reveals. Session replacement clears both searches and all search-owned disclosure state.
- [x] Closing Review Search stops queued search work. Shutdown and Session replacement reject late command ids, Query generations, and Session Epochs while releasing every owned Batch and lease.
- [x] Partial File failure preserves usable opposite-version results and exact authored results. A classified failure does not replace the prior complete Frame.
- [x] Allocation failure during Query construction, Candidate building, matching, lease creation, publication, or destination Frame construction preserves the prior complete Frame and frees owned data.
- [x] The complete acceptance matrix covers Unicode, literal and fuzzy matching, ReviewBody mapping, Search Occurrence identity, both search interactions, Overlay rendering, pointer parity, acquisition, retry, cache leases, stale work, source and authored opening, search lifetime, and unconditional wrapping.
- [x] `zig build test --summary all` passes and reports more tests than before M21 implementation. Live Bitbucket and PTY checks remain optional.

## Comments

Exact source opening and search lifetime checks shipped in `43c32fb` and `ccb9207`.
`zig build test --summary all` passed 828/828 tests.
