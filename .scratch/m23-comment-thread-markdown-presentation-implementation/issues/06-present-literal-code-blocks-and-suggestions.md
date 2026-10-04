# 06 — Present literal code blocks and Suggestions

**What to build:** Read complete code blocks and Suggestions without Markdown or emoji changes to their code. Wrap narrow code, show tabs, and copy exact authored lines with their required existing fences.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** ready-for-agent

- [ ] Recognize root indented code and backtick or tilde fences. An opening fence has at least three matching characters.
- [ ] A closing fence uses the opening character and at least the opening length. Hide only recognized delimiters.
- [ ] Preserve Suggestions as distinct replacement-code blocks with their existing label and Theme background.
- [ ] Remove only structural container and code-block indentation. Keep the remaining whitespace, Markdown characters, emoji shortcodes, HTML, and language directives literal.
- [ ] Preserve spaces and tabs in code. A tab advances to the next multiple of four terminal columns from the code content origin.
- [ ] ReviewCard and Reply offsets do not change that origin. Wrapped code retains every content byte without truncation.
- [ ] Use a lighter code background in dark Themes and a darker code background in light Themes. Plain blocks use the ordinary Theme foreground.
- [ ] Keep Suggestions on their distinct background. Cursor, Selection, and search backgrounds preserve code foregrounds and literal content.
- [ ] An unclosed fence or Suggestion remains locally literal. An unclosed Suggestion no longer makes the complete body literal.
- [ ] Review Search Preview shares code text, whitespace, wrapping, backgrounds, and fallback with ReviewCards.
- [ ] Both searches find literal code line by line. Exclude recognized fence delimiters and metadata, generated labels, and tab-expansion decoration.
- [ ] Selection of valid fenced code or Suggestion content includes both existing authored fence lines, with original metadata and indentation.
- [ ] Copy selected code lines and fences in authored order once per owner. Do not add unselected code lines or invent missing fences.
- [ ] Indented code adds no fences. Malformed literal delimiters use the ordinary touched-line rule.
- [ ] Verify exact tabs, line endings, partial fenced-code copying, malformed Suggestions beside valid prose, and narrow code in both layouts.
- [ ] Ordinary editing retains raw Markdown. Suggestion Composer retains its existing replacement-code contract.
- [ ] Run `zig build test --summary all`.

## Contract

Use the [M23 literal code contract](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#literal-code-and-highlighting) and the [Selection ownership answer](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#required-hidden-lines).
Ticket 07 adds code inside lists and quotes. Tickets 11 and 12 add syntax foregrounds.
