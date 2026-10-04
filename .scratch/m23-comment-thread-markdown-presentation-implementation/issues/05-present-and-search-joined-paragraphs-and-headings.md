# 05 — Present and search joined paragraphs and headings

**What to build:** Show paragraph structure and heading levels in ReviewCards and Preview. Let both searches find prose across ordinary authored line endings and focus every matched part precisely.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** ready-for-agent

- [ ] Support ATX and Setext headings. Show generated `§1` through `§6` markers and bold heading text with the agreed inline style precedence.
- [ ] Hide recognized heading delimiters and Setext underlines. Preserve their authored ranges for copying.
- [ ] Present one blank row between paragraphs. Join ordinary paragraph line endings as spaces. Two trailing spaces create a hard break.
- [ ] Both searches match semantic paragraph regions rather than terminal rows. Map a matched join space to its authored line ending.
- [ ] Retain exact UTF-8 ranges across every matched authored line. Report the first matched authored line and one-based Unicode scalar column.
- [ ] Buffer Search returns leftmost, non-overlapping literal matches in semantic corpus order. Review Search returns one best fuzzy match per paragraph region.
- [ ] Blank lines, hard breaks, separate bodies, and distinct link regions stop matching. Nonjoined code and source File text remain line-local.
- [ ] Keep M21 smart case, query validation, length limits, Unicode folding, fuzzy work limits, ranking, and corpus exclusions.
- [ ] Generated heading markers, disclosure text, and generated spacers do not participate in matching.
- [ ] Navigation focuses the exact owner and first wrapped row containing the match. Every projected matched part receives search emphasis.
- [ ] Buffer Search temporarily opens required disclosures and restores saved choices. Review Search saves required disclosures after the destination Frame exists.
- [ ] Preview uses the same headings, paragraphs, wrapping, and styles as ReviewCards. Keep authored result positions distinct from terminal columns.
- [ ] Resizing and disclosure retain occurrence identity and counts. Body replacement rebuilds relevant matching data. Session replacement clears both searches.
- [ ] Selection copies only touched authored lines from joined paragraphs. Selecting Setext heading content also copies its existing underline.
- [ ] A selected compressed spacer copies only its first represented authored blank line. A generated marker-only row emits no clipboard command.
- [ ] Verify the approved joined-prose, wrapped-prose, Setext, spacer, and search-reveal exact-byte examples through Presentation.
- [ ] Matching or projection failure preserves the previous complete Frame. Run `zig build test --summary all`.

## Contract

Use the [approved search answer](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#answer) and the [exact clipboard-byte examples](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples).
Tickets 07, 08, 09, and 10 extend these semantic rules to their supported syntax.
