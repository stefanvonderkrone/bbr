# 09 — Present tables at wide and narrow widths

**What to build:** Read every supported table cell at wide and narrow widths without discarded content. Search authored cells once and copy the correct raw table rows.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** resolved

- [x] Recognize a table through its header and separator rows. Apply separator alignment and inline styles to cells.
- [x] Escaped pipes and inline-code pipes do not split cells. Missing cells are empty.
- [x] A row with extra cells remains literal without discarded text. Local fallback does not remove valid formatting elsewhere.
- [x] Use aligned columns when the complete table fits the available ReviewCard body width.
- [x] At narrow widths, show each row as wrapped, header-labelled cells. Keep every cell's content available through disclosure.
- [x] Preview uses the same wide and narrow table rules as ReviewCards.
- [x] Both searches use semantic authored cell content. Distinct cells remain matching boundaries.
- [x] Search each authored header occurrence once. Repeated narrow header labels and generated borders add no occurrences.
- [x] Search navigation reaches the correct authored owner and visible cell. Width changes retain counts and occurrence identity.
- [x] Selecting a narrow cell copies its complete authored table row once per owner. Repeated header labels do not add the authored header line.
- [x] Actual selected header content contributes its own authored line. Selecting table content also copies its required separator line.
- [x] Do not imply an unselected header, other rows, or adjacent blank lines. Copy the authored set in original line order.
- [x] Malformed literal rows use touched-line extraction. Preserve exact pipe escapes, spaces, line endings, and Markdown bytes.
- [x] Verify wide and narrow projection, cell alignment, code pipes, escaped pipes, missing cells, extra cells, disclosure, and exact clipboard bytes.
- [x] Cover both layouts and all applicable Theme styles. Run `zig build test --summary all`.

## Contract

Use the [approved table presentation](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#tables) and the [exact clipboard-byte examples](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples).

## Implementation

ReviewBody stores each authored table row with its cell spans and separator alignment.
The shared pipe scanner protects escaped pipes and matched inline-code pipes.
Rows with extra cells remain literal.
Table boundaries preserve headings, code, quotes, lists, and reference definitions.

ReviewCard projection measures every valid cell before it selects the wide or narrow layout.
Preview uses the same projection.
Narrow header labels and wide column borders remain generated decoration.
Both searches keep distinct cells as separate matching regions.
Selection uses the existing authored-line extraction and required hidden-line rules to copy table rows and their separator.

The Standards and Spec reviews found three parser defects.
Regression tests cover stalled parsing, consumed block boundaries, and false table recognition from protected pipes.
The final reviews found no remaining findings.

## Verification

The approved seams cover ReviewBody, row projection, headless rendering, and Presentation Actions.
The tests cover both layouts, RemoteReview and LocalReview navigation, every built-in Theme, and exact clipboard bytes.

These commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target:

- `zig test src/tui/review_body.zig --test-filter 'M23 tables'`. All 5 table tests passed after the final fixes.
- `zig test --dep bbr -Mroot=src/tui/review_card.zig -Mbbr=src/root.zig --test-filter 'M23 tables'`.
- `zig test --dep bbr -Mroot=src/tui/search.zig -Mbbr=src/root.zig --test-filter 'M23 tables'`.
- `zig build test-tables --summary all`. All 14 tests passed.
- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`. All 1,036 tests passed.
