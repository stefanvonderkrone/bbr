# 07 — Present nested lists and quotes

**What to build:** Read nested lists and quotes with clear hierarchy and aligned continuation text. Keep their prose searchable and their authored container bytes copyable.

**Blocked by:** 05 — Present and search joined paragraphs and headings. 06 — Present literal code blocks and Suggestions.

**Status:** resolved

- [x] Display unordered list markers as bullets. Accept digit-plus-period ordered markers and keep closing-parenthesis markers literal.
- [x] Increment ordered numbering from the first authored number, regardless of later authored numbers in that list.
- [x] Require a blank line after preceding prose and between different sibling list types.
- [x] Use four authored spaces and two displayed spaces per nested list level. Support either list type within either parent type.
- [x] Align wrapped continuation text with item text rather than the marker.
- [x] Show one vertical bar per quote level. Lists and code inside quotes retain their own presentation rules.
- [x] Support backtick fences, tilde fences, and indented code inside supported list and quote containers.
- [x] Remove only structural container and code-block indentation from code presentation. Container offsets do not change code tab stops.
- [x] Apply the existing inline styles and code backgrounds within the width available to each ReviewCard.
- [x] Preview shares the same container projection and wrapping rules as ReviewCards.
- [x] Both searches join ordinary continuation lines within one list-item or quote paragraph. Distinct items, hard breaks, blank lines, and code lines remain boundaries.
- [x] Exclude generated numbering, bullets, and quote bars from search. Keep unsupported or malformed markers searchable as literal content.
- [x] Selection copies complete touched authored lines with original markers and indentation. Selected container code also copies required existing fences.
- [x] Generated marker-only rows contribute nothing. Resize does not add clipboard lines or change occurrence identity merely through wrapping.
- [x] Verify mixed nesting, numbering from a non-one start, blank-line boundaries, wrapped continuations, nested code, and narrow Reply bodies.
- [x] Label synthetic syntax examples as project behavior rather than observed Cloud behavior. Run `zig build test --summary all`.

## Contract

Use the [approved Markdown answer](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#headings-paragraphs-lists-and-quotes) and the [paragraph matching rules](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#paragraph-joins-and-matching-units).
The final human review captures observed Cloud list evidence in ticket 14.

## Implementation

ReviewBody retains container offsets and generated markers separately from authored spans.
Ordered lists retain their first number and increment later items.
List and quote paragraphs share inline styles across ordinary authored line endings.
Container code removes structural indentation and retains the existing fences for Selection copying.

ReviewCards and Preview share the container projection.
Wrapped item text aligns with the item text column.
Narrow rows reserve enough cells for a complete wide grapheme before they add container markers.
Code tabs use the code content origin.

Both searches use the same authored container spans and paragraph joins.
Generated markers do not enter the search corpus or contribute clipboard bytes by themselves.
Synthetic checks define project behavior rather than observed Cloud behavior.

## Review

The Standards review identified duplicate row emission and reset logic.
The projection now shares that logic.
The Spec review identified wide-character clipping and literal quotes inside list items.
Failing regression checks confirmed both defects before the fixes.
The next Spec review identified incomplete alternating quote and list containers.
The projection now retains the authored container order through prose, code, and search.
The final Standards and Spec reviews found no remaining findings.

## Verification

The approved seams cover ReviewBody, row projection, headless rendering, and Presentation Actions.
The container checks cover mixed nesting, non-one numbering, blank-line boundaries, and both searches.
The clipboard checks cover original container bytes, existing fences, and generated marker-only rows.
Preview checks cover the existing inline styles and code backgrounds in every built-in Theme.

The following commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target.

- `zig test src/tui/review_body.zig`. All 10 tests passed.
- `zig test --dep bbr -Mroot=src/tui/search.zig -Mbbr=src/root.zig --test-filter 'M23 containers'`. All 4 tests passed.
- `zig build test-containers --summary all`. All 15 tests passed.
- `zig fmt --check build.zig src tests`
- `zig build`
- `zig build test --summary all`. All 1011 tests passed.

The final full-suite run followed the fixes from code review.
