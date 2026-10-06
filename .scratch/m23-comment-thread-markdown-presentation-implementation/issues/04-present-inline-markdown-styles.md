# 04 — Present inline Markdown styles

**What to build:** Present authored inline Markdown with readable Theme styles in ReviewCards and Review Search Preview. Keep search and Selection copying tied to authored content.

**Blocked by:** 03 — Yank mixed source and ReviewCard Selection.

**Status:** resolved

- [x] Hide valid asterisk and underscore emphasis delimiters. Keep intraword underscores literal.
- [x] Support literal inline code, including its whitespace, Markdown characters, HTML, and emoji shortcodes. Hide only recognized delimiters.
- [x] Use Theme defaults of turquoise for italic, orange for bold, and green for inline code.
- [x] Apply foreground precedence of inline code, bold, italic, then ordinary text. Combine applicable bold, italic, strikethrough, and link underline attributes.
- [x] Preserve Markdown foregrounds and attributes under cursor, Selection, and search backgrounds, including overlapping interaction backgrounds.
- [x] Draft ownership does not make the complete body bold. Keep Draft identity visible through its header and role.
- [x] Use terminal strikethrough when available. Otherwise show the authored strikethrough delimiters.
- [x] Hide escape backslashes for escaped punctuation. Keep the escaped punctuation literal and retain its source ownership.
- [x] Keep authored HTML tags, entity spellings, product references, and excluded Cloud extensions literal.
- [x] Limit malformed-construct fallback to the affected construct. Valid formatting elsewhere remains active without discarded text.
- [x] Keep ReviewBody width-independent. Preserve authored ranges for visible content, hidden delimiters, and generated decoration without equal-length assumptions.
- [x] Present inline formatting in the selected Review Search Preview through the same ReviewBody rules as ReviewCards.
- [x] Both searches find semantic inline content across hidden delimiters. Exclude hidden delimiters and generated text from matching.
- [x] Map matches to exact authored UTF-8 ranges and the correct wrapped cells. Preserve occurrence identity after resize or Theme changes.
- [x] Selection copies complete touched authored lines rather than styled text. Complete-body copying, ordinary Composer, External Edit, and Submission retain authored bytes.
- [x] Verify combined styles in every applicable built-in Theme and ReviewCard role through headless rendering and Presentation Actions.
- [x] A failed reprojection preserves the previous complete Frame. Run `zig build test --summary all`.

## Contract

Use the [M23 syntax and style contract](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#reviewbody-syntax-and-styles) and the [approved Markdown answer](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#answer).
Use the existing M21 search rules except for explicit M23 changes. Ticket 05 adds joined paragraph matching.

## Implementation

ReviewBody matches emphasis delimiter runs and retains exact ranges for hidden syntax.
Inline code keeps its spaces, tabs, line breaks, Markdown, HTML, and shortcode bytes literal.
Escaped punctuation retains its authored ownership.
An unclosed Suggestion now falls back locally instead of replacing the complete body.

Theme roles supply turquoise italic text, orange bold text, and green inline code.
Light Themes use darker foregrounds for these roles.
The system Theme uses terminal palette colors.
Draft headers remain bold, but ordinary Draft bodies use regular weight.

ReviewCards and Review Search Preview use the same ReviewBody parser and row projection.
Both presentations use the terminal metrics that Presentation supplies.
The vaxis adapter uses SGR 9 for strikethrough.
An adapter that disables `CellMetrics.strikethrough_supported` retains the authored delimiters in both presentations.
Search ignores hidden syntax and generated decoration.
Search reports exact authored UTF-8 ranges and one-based authored Unicode columns.
Generated link markers no longer overlap the authored match ranges of other wrapped rows.

## Verification

The approved seams cover ReviewBody, row projection, headless rendering, and Presentation Actions.
The checks include all built-in Themes and ReviewCard roles.
Presentation checks cover both layouts and RemoteReview and LocalReview.
They inspect exact Selection bytes, complete-body bytes, Composer bytes, External Edit bytes, search locations, and Frame rollback.
Allocation-failure checks verify that ReviewBody releases partial allocations.

The following commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target.

- `zig test src/tui/review_body.zig`
- `zig build test-inline-markdown test-search-kernel test-authored-search test-yank --summary all`. All 195 tests passed.
- `zig build`
- `zig fmt --check build.zig src tests`
- `git diff --check`
- `zig build test --summary all`. All 984 tests passed.

The first full-suite attempt exceeded the tool's 120-second limit.
The retry with a 600-second limit passed.

## Review

The Standards review found duplicate terminal metrics.
The terminal adapter and Preview now share `render.terminal_cell_metrics`.
The Spec review found that Preview did not use the strikethrough fallback capability.
Preview now uses the same supplied metrics as ReviewCards.
Additional checks cover escaped link labels and literal inline-code line breaks.
The final Standards and Spec reviews found no remaining findings for this ticket.

These checks are project acceptance evidence.
The linked human format-combination checklist remains part of the final M23 acceptance review.
