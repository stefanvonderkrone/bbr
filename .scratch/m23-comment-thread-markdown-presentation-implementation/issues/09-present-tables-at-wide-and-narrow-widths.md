# 09 — Present tables at wide and narrow widths

**What to build:** Read every supported table cell at wide and narrow widths without discarded content. Search authored cells once and copy the correct raw table rows.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** ready-for-agent

- [ ] Recognize a table through its header and separator rows. Apply separator alignment and inline styles to cells.
- [ ] Escaped pipes and inline-code pipes do not split cells. Missing cells are empty.
- [ ] A row with extra cells remains literal without discarded text. Local fallback does not remove valid formatting elsewhere.
- [ ] Use aligned columns when the complete table fits the available ReviewCard body width.
- [ ] At narrow widths, show each row as wrapped, header-labelled cells. Keep every cell's content available through disclosure.
- [ ] Preview uses the same wide and narrow table rules as ReviewCards.
- [ ] Both searches use semantic authored cell content. Distinct cells remain matching boundaries.
- [ ] Search each authored header occurrence once. Repeated narrow header labels and generated borders add no occurrences.
- [ ] Search navigation reaches the correct authored owner and visible cell. Width changes retain counts and occurrence identity.
- [ ] Selecting a narrow cell copies its complete authored table row once per owner. Repeated header labels do not add the authored header line.
- [ ] Actual selected header content contributes its own authored line. Selecting table content also copies its required separator line.
- [ ] Do not imply an unselected header, other rows, or adjacent blank lines. Copy the authored set in original line order.
- [ ] Malformed literal rows use touched-line extraction. Preserve exact pipe escapes, spaces, line endings, and Markdown bytes.
- [ ] Verify wide and narrow projection, cell alignment, code pipes, escaped pipes, missing cells, extra cells, disclosure, and exact clipboard bytes.
- [ ] Cover both layouts and all applicable Theme styles. Run `zig build test --summary all`.

## Contract

Use the [approved table presentation](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#tables) and the [exact clipboard-byte examples](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples).
