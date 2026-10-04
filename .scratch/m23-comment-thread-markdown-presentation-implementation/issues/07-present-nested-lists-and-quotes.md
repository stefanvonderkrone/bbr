# 07 — Present nested lists and quotes

**What to build:** Read nested lists and quotes with clear hierarchy and aligned continuation text. Keep their prose searchable and their authored container bytes copyable.

**Blocked by:** 05 — Present and search joined paragraphs and headings. 06 — Present literal code blocks and Suggestions.

**Status:** ready-for-agent

- [ ] Display unordered list markers as bullets. Accept digit-plus-period ordered markers and keep closing-parenthesis markers literal.
- [ ] Increment ordered numbering from the first authored number, regardless of later authored numbers in that list.
- [ ] Require a blank line after preceding prose and between different sibling list types.
- [ ] Use four authored spaces and two displayed spaces per nested list level. Support either list type within either parent type.
- [ ] Align wrapped continuation text with item text rather than the marker.
- [ ] Show one vertical bar per quote level. Lists and code inside quotes retain their own presentation rules.
- [ ] Support backtick fences, tilde fences, and indented code inside supported list and quote containers.
- [ ] Remove only structural container and code-block indentation from code presentation. Container offsets do not change code tab stops.
- [ ] Apply the existing inline styles and code backgrounds within the width available to each ReviewCard.
- [ ] Preview shares the same container projection and wrapping rules as ReviewCards.
- [ ] Both searches join ordinary continuation lines within one list-item or quote paragraph. Distinct items, hard breaks, blank lines, and code lines remain boundaries.
- [ ] Exclude generated numbering, bullets, and quote bars from search. Keep unsupported or malformed markers searchable as literal content.
- [ ] Selection copies complete touched authored lines with original markers and indentation. Selected container code also copies required existing fences.
- [ ] Generated marker-only rows contribute nothing. Resize does not add clipboard lines or change occurrence identity merely through wrapping.
- [ ] Verify mixed nesting, numbering from a non-one start, blank-line boundaries, wrapped continuations, nested code, and narrow Reply bodies.
- [ ] Label synthetic syntax examples as project behavior rather than observed Cloud behavior. Run `zig build test --summary all`.

## Contract

Use the [approved Markdown answer](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#headings-paragraphs-lists-and-quotes) and the [paragraph matching rules](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#paragraph-joins-and-matching-units).
The final human review captures observed Cloud list evidence in ticket 14.
