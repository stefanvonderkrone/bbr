# 12 — Highlight Suggestions and prioritize selected Preview

**What to build:** Use the authored inline File context to color Suggestion replacement code. Give visible code in the selected Review Search Preview priority through the same bounded Highlighting system.

**Blocked by:** 05 — Present and search joined paragraphs and headings. 11 — Highlight fenced code with bounded background work.

**Status:** ready-for-agent

- [ ] A recognized Suggestion uses its root's authored inline File path and replacement code through normal GrammarMatch. Replies inherit that root context.
- [ ] Moved and Outdated Suggestions retain the original authored path. Missing context leaves the Suggestion plain.
- [ ] Do not use the cursor File, infer a replacement path, acquire File content, or wait for File Enrichment.
- [ ] Suggestions retain their distinct background and label under syntax colors and plain fallback.
- [ ] The selected Preview makes its visible code blocks eligible even when the corresponding ReviewCard is outside the viewport or collapsed.
- [ ] Pending Preview work precedes pending ReviewCard work. Preserve authored block order within the Preview.
- [ ] Changing the selected result or closing the Overlay removes that Preview's pending eligibility. Already-started work continues to completion.
- [ ] Preview and ReviewCards share accepted block results, one worker, the complete-block byte limit, and the 8 MiB retained-capacity budget.
- [ ] Visible Preview blocks count as visible presentations for result use and eviction. Do not analyze every search result or add a separate Preview budget.
- [ ] Preview uses the same ReviewBody formatting, code backgrounds, literal content, and Grammar fallback as ReviewCards.
- [ ] Show complete plain Preview code before colors arrive. Search backgrounds preserve Markdown attributes and syntax foregrounds.
- [ ] Theme, wrapping, disclosure, and resize reuse results. Color arrival changes no text, geometry, ownership, cursor, Selection, or Search Occurrence identity.
- [ ] Reject stale completions after Session, body, or Grammar context changes. Preserve the previous complete Frame on admission failure.
- [ ] Verify authored path retention after rename, inherited Reply context, absent context, Preview priority, shared-result reuse, and Overlay eligibility removal.
- [ ] Cover RemoteReview and LocalReview where applicable. Run `zig build test --summary all`.

## Contract

Use the [approved Suggestion context](../../m23-comment-thread-markdown-presentation-fixes/issues/05-choose-reviewbody-code-block-highlighting.md#suggestions) and the [formatted Preview and priority contract](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#formatted-preview-and-code-block-highlighting).
