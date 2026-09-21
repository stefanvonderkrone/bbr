# 11 — Add Buffer Search

**What to build:** A reviewer can press `/` to search semantic source and ReviewBody text in the current Buffer. Incremental feedback, highlights, `n` and `N` traversal, Count, and cancellation work without starting File Enrichment.

**Blocked by:** 10 — Add the Search Kernel and Reachable Source.

**Status:** ready-for-agent

- [ ] Configurable Buffer Search Actions default to `/`, `n`, and `N` in every DiffPane Interaction Context.
- [ ] Presentation refuses Buffer Search while Selection is active and tells the reviewer to clear Selection first.
- [ ] Query input appends and removes complete Unicode scalars. Backspace, `ctrl-w`, `ctrl-u`, Query validation, and the 256-scalar limit give visible deterministic results.
- [ ] Every nonempty edit updates literal smart-case Search Occurrences, the active occurrence, highlights, and the `active/total` count in one complete Presentation Frame.
- [ ] The corpus follows Layout, Scope, and File isolation. It includes hidden Fold Lines and collapsed Thread and ReviewCard bodies, but it never starts File Enrichment.
- [ ] Shared context and wrapped source each count once. Same-Line occurrences run left to right, and SideBySide old occurrences precede new occurrences.
- [ ] `Enter` accepts the preview. An empty accepted Query reuses the prior Query, and a no-match Query remains active with `0/0` feedback.
- [ ] `Esc` restores the saved cursor, scroll, Query, Search Occurrences, active occurrence, highlights, and disclosure state.
- [ ] `n`, `N`, and Count traverse semantic Search Occurrences with wraparound and the specified top or bottom status message.
- [ ] Manual DiffPane navigation clears only the active occurrence. It retains the accepted Query and all non-active match highlights.
- [ ] An active hidden occurrence opens only its required search-owned disclosures. Leaving the occurrence restores the reviewer's saved disclosure state.
- [ ] Buffer reprojection rebuilds Search Occurrences and retains a surviving active identity across Layout, Scope, isolation, disclosure, and ReviewBody changes.
- [ ] The command line keeps the prompt and Query end visible before the count. Every built-in Theme shows match, active-match, and no-match feedback without erasing syntax attributes.
- [ ] Allocation, Candidate, scan, or Frame failure preserves the prior complete Presentation Frame and reports a classified error.
- [ ] Presentation and headless rendering tests cover the Buffer corpus, Query lifecycle, traversal, disclosure, Count, narrow terminals, styles, and reprojection.
