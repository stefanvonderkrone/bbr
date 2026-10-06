# 05 — Present and search joined paragraphs and headings

**What to build:** Show paragraph structure and heading levels in ReviewCards and Preview. Let both searches find prose across ordinary authored line endings and focus every matched part precisely.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** resolved

- [x] Support ATX and Setext headings. Show generated `§1` through `§6` markers and bold heading text with the agreed inline style precedence.
- [x] Hide recognized heading delimiters and Setext underlines. Preserve their authored ranges for copying.
- [x] Present one blank row between paragraphs. Join ordinary paragraph line endings as spaces. Two trailing spaces create a hard break.
- [x] Both searches match semantic paragraph regions rather than terminal rows. Map a matched join space to its authored line ending.
- [x] Retain exact UTF-8 ranges across every matched authored line. Report the first matched authored line and one-based Unicode scalar column.
- [x] Buffer Search returns leftmost, non-overlapping literal matches in semantic corpus order. Review Search returns one best fuzzy match per paragraph region.
- [x] Blank lines, hard breaks, separate bodies, and distinct link regions stop matching. Nonjoined code and source File text remain line-local.
- [x] Keep M21 smart case, query validation, length limits, Unicode folding, fuzzy work limits, ranking, and corpus exclusions.
- [x] Generated heading markers, disclosure text, and generated spacers do not participate in matching.
- [x] Navigation focuses the exact owner and first wrapped row containing the match. Every projected matched part receives search emphasis.
- [x] Buffer Search temporarily opens required disclosures and restores saved choices. Review Search saves required disclosures after the destination Frame exists.
- [x] Preview uses the same headings, paragraphs, wrapping, and styles as ReviewCards. Keep authored result positions distinct from terminal columns.
- [x] Resizing and disclosure retain occurrence identity and counts. Body replacement rebuilds relevant matching data. Session replacement clears both searches.
- [x] Selection copies only touched authored lines from joined paragraphs. Selecting Setext heading content also copies its existing underline.
- [x] A selected compressed spacer copies only its first represented authored blank line. A generated marker-only row emits no clipboard command.
- [x] Verify the approved joined-prose, wrapped-prose, Setext, spacer, and search-reveal exact-byte examples through Presentation.
- [x] Matching or projection failure preserves the previous complete Frame. Run `zig build test --summary all`.

## Contract

Use the [approved search answer](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#answer) and the [exact clipboard-byte examples](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples).
Tickets 07, 08, 09, and 10 extend these semantic rules to their supported syntax.

## Implementation

ReviewBody recognizes ATX heading levels, optional closing delimiters, and Setext underlines.
ReviewCards and Preview share generated heading markers, bold heading content, paragraph joins, and hard breaks.
Setext content retains its hidden underline for Selection copying.
Compressed spacers retain only their first authored blank line as a Selection contribution.

Both searches build candidates from semantic paragraph regions.
Mappings retain authored line numbers, Unicode scalar columns, and exact UTF-8 ranges.
A joined space maps to its authored line ending, including both CRLF bytes.
Literal matches retain authored order when a paragraph spans several lines.
Hard breaks and literal code lines start separate matching regions.
Link destinations retain their existing matching boundaries.

Buffer Search reveals every matched paragraph row, including matches whose first row is already visible.
The search projection excludes disclosure footers from authored body rows.
A wrapped join retains its authored line ending for exact navigation even when wrapping removes the displayed space.
Review Search saves disclosures only after it publishes the destination Frame.

## Verification

The approved seams cover ReviewBody, row projection, headless rendering, and Presentation Actions.
New checks cover heading levels, malformed headings, CRLF joins, hard breaks, literal ordering, and fuzzy paragraph matching.
Presentation checks verify the approved joined-prose, wrapped-prose, Setext, spacer, and search-reveal clipboard bytes.
Search reveal checks cover both layouts and both review modes.
Headless Preview checks cover every built-in Theme.
Existing checks retain search validation, lifecycle, disclosure restoration, and Frame rollback coverage.

The following commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target.

- `zig build test-inline-markdown test-search-kernel test-authored-search test-yank --summary all`. All 204 tests passed.
- `zig build`
- `zig fmt --check build.zig src tests`
- `zig build test --summary all`. All 992 tests passed.

The final full-suite attempt exceeded the tool's 120-second limit.
The retry with a 600-second limit passed.

## Review

The Standards review found a private test-queue read and related search-region arrays passed separately.
The test now drains typed commands through `takeCommand()`.
`BodyRegion` groups the arrays.
Both reviews found that inline-code breaks lost empty authored rows.
The Spec review also found that Setext recognition accepted excessive tab indentation.
Failing regression checks confirmed both defects before the fixes.
The final Standards and Spec reviews found no remaining findings in those fixes.
