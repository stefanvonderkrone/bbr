# 04 — Present inline Markdown styles

**What to build:** Present authored inline Markdown with readable Theme styles in ReviewCards and Review Search Preview. Keep search and Selection copying tied to authored content.

**Blocked by:** 03 — Yank mixed source and ReviewCard Selection.

**Status:** ready-for-agent

- [ ] Hide valid asterisk and underscore emphasis delimiters. Keep intraword underscores literal.
- [ ] Support literal inline code, including its whitespace, Markdown characters, HTML, and emoji shortcodes. Hide only recognized delimiters.
- [ ] Use Theme defaults of turquoise for italic, orange for bold, and green for inline code.
- [ ] Apply foreground precedence of inline code, bold, italic, then ordinary text. Combine applicable bold, italic, strikethrough, and link underline attributes.
- [ ] Preserve Markdown foregrounds and attributes under cursor, Selection, and search backgrounds, including overlapping interaction backgrounds.
- [ ] Draft ownership does not make the complete body bold. Keep Draft identity visible through its header and role.
- [ ] Use terminal strikethrough when available. Otherwise show the authored strikethrough delimiters.
- [ ] Hide escape backslashes for escaped punctuation. Keep the escaped punctuation literal and retain its source ownership.
- [ ] Keep authored HTML tags, entity spellings, product references, and excluded Cloud extensions literal.
- [ ] Limit malformed-construct fallback to the affected construct. Valid formatting elsewhere remains active without discarded text.
- [ ] Keep ReviewBody width-independent. Preserve authored ranges for visible content, hidden delimiters, and generated decoration without equal-length assumptions.
- [ ] Present inline formatting in the selected Review Search Preview through the same ReviewBody rules as ReviewCards.
- [ ] Both searches find semantic inline content across hidden delimiters. Exclude hidden delimiters and generated text from matching.
- [ ] Map matches to exact authored UTF-8 ranges and the correct wrapped cells. Preserve occurrence identity after resize or Theme changes.
- [ ] Selection copies complete touched authored lines rather than styled text. Complete-body copying, ordinary Composer, External Edit, and Submission retain authored bytes.
- [ ] Verify combined styles in every applicable built-in Theme and ReviewCard role through headless rendering and Presentation Actions.
- [ ] A failed reprojection preserves the previous complete Frame. Run `zig build test --summary all`.

## Contract

Use the [M23 syntax and style contract](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#reviewbody-syntax-and-styles) and the [approved Markdown answer](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#answer).
Use the existing M21 search rules except for explicit M23 changes. Ticket 05 adds joined paragraph matching.
