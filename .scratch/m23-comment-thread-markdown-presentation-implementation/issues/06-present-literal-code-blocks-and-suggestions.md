# 06 — Present literal code blocks and Suggestions

**What to build:** Read complete code blocks and Suggestions without Markdown or emoji changes to their code. Wrap narrow code, show tabs, and copy exact authored lines with their required existing fences.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** resolved

- [x] Recognize root indented code and backtick or tilde fences. An opening fence has at least three matching characters.
- [x] A closing fence uses the opening character and at least the opening length. Hide only recognized delimiters.
- [x] Preserve Suggestions as distinct replacement-code blocks with their existing label and Theme background.
- [x] Remove only structural container and code-block indentation. Keep the remaining whitespace, Markdown characters, emoji shortcodes, HTML, and language directives literal.
- [x] Preserve spaces and tabs in code. A tab advances to the next multiple of four terminal columns from the code content origin.
- [x] ReviewCard and Reply offsets do not change that origin. Wrapped code retains every content byte without truncation.
- [x] Use a lighter code background in dark Themes and a darker code background in light Themes. Plain blocks use the ordinary Theme foreground.
- [x] Keep Suggestions on their distinct background. Cursor, Selection, and search backgrounds preserve code foregrounds and literal content.
- [x] An unclosed fence or Suggestion remains locally literal. An unclosed Suggestion no longer makes the complete body literal.
- [x] Review Search Preview shares code text, whitespace, wrapping, backgrounds, and fallback with ReviewCards.
- [x] Both searches find literal code line by line. Exclude recognized fence delimiters and metadata, generated labels, and tab-expansion decoration.
- [x] Selection of valid fenced code or Suggestion content includes both existing authored fence lines, with original metadata and indentation.
- [x] Copy selected code lines and fences in authored order once per owner. Do not add unselected code lines or invent missing fences.
- [x] Indented code adds no fences. Malformed literal delimiters use the ordinary touched-line rule.
- [x] Verify exact tabs, line endings, partial fenced-code copying, malformed Suggestions beside valid prose, and narrow code in both layouts.
- [x] Ordinary editing retains raw Markdown. Suggestion Composer retains its existing replacement-code contract.
- [x] Run `zig build test --summary all`.

## Contract

Use the [M23 literal code contract](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#literal-code-and-highlighting) and the [Selection ownership answer](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#required-hidden-lines).
Ticket 07 adds code inside lists and quotes. Tickets 11 and 12 add syntax foregrounds.

## Implementation

ReviewBody recognizes complete root fences and root indented code.
It removes structural code indentation and retains the remaining authored code bytes.
Unclosed fences retain local literal content and leave earlier prose formatting active.
ReviewCards and Review Search Preview share code wrapping and tab expansion from the code content origin.
Plain code uses the ordinary Theme foreground and a separate code background.
Suggestions keep their existing label and Theme style.

Selection copies touched authored code lines with both existing fence lines.
The existing owner-and-line deduplication and authored-order copy rules apply to those fences.
Indented code and malformed literal content add no fences.
Both searches use authored code lines and exclude recognized fence metadata and generated text.

## Verification

The approved checks cover ReviewBody, projection, headless rendering, both search modes, and Presentation clipboard commands.
They include narrow wrapping, Reply offsets, mixed indentation, tabs, CRLF, partial copying, and unclosed Suggestions beside valid prose.
Headless checks cover every built-in Theme and ReviewCard role under cursor, Selection, and search backgrounds.
The full suite also verifies the existing Composer and Suggestion replacement-code behavior.

The following commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target.

- `zig test src/tui/review_body.zig`. All 7 tests passed.
- `zig test --dep bbr -Mroot=src/tui/review_card.zig -Mbbr=src/root.zig`.
- `zig test --dep bbr -Mroot=src/tui/search.zig -Mbbr=src/root.zig --test-filter 'M23 literal'`.
- `zig build test-literal-code --summary all`. All 10 tests passed.
- `zig build test-yank --summary all`. All 32 tests passed.
- `zig build test-inline-markdown --summary all`. All 22 tests passed.
- `zig build`.
- `zig fmt --check build.zig src tests`.
- `git diff --check`.
- `zig build test --summary all`. All 999 tests passed.

The first full-suite attempt exceeded the tool's 120-second limit.
The retry with a 600-second limit passed.

## Review

The Standards and Spec reviews inspected the work against starting commit `fab2333`.
Both reviews found no findings for ticket 06.
These checks are project acceptance evidence.
The final M23 human format-combination review remains part of the milestone acceptance contract.
