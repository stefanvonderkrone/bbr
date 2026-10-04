# 10 — Convert and search emoji shortcodes

**What to build:** Display known authored emoji shortcodes as their exact fixture Unicode bytes. Let either displayed Unicode or authored shortcode text find the same location without changing copied content.

**Blocked by:** 05 — Present and search joined paragraphs and headings. 06 — Present literal code blocks and Suggestions.

**Status:** ready-for-agent

- [ ] Use the pinned Atlassian standard fixture's exact names and Unicode fallback bytes, including listed compound skin-tone names.
- [ ] Retain the pinned source and applicable attribution with the shipped data. Describe the mapping as best-effort, not a complete Cloud catalog.
- [ ] Match catalog names case-sensitively. Do not infer aliases, convert ASCII emoticons, or normalize Unicode.
- [ ] Convert visible prose and link labels through the shared inline rules. The same rules apply to headings, lists, quotes, and table text when available.
- [ ] Keep code, destinations, escaped names, and unknown names literal. Authored Unicode does not acquire an inferred shortcode.
- [ ] ReviewCards and Preview use the same conversion and terminal-column measurements. Preserve compound sequences without fixed prototype width assumptions.
- [ ] Both searches permit each converted emoji to supply either displayed Unicode or exact authored shortcode text within one match.
- [ ] Allow different emoji to use different forms within one match. One emoji cannot supply both forms in sequence.
- [ ] Permit shortcode substrings. Map either form to the complete authored shortcode or compound shortcode range.
- [ ] Partial shortcode or Unicode matches emphasize the complete displayed emoji. Code points and terminal cells do not add occurrences.
- [ ] Count and deduplicate by authored location. Keep leftmost non-overlapping Buffer Search behavior and the best Review Search match per region.
- [ ] Apply M21 smart case, fuzzy scores, work limits, and deterministic ordering to legal representations.
- [ ] Equal representations prefer displayed text, then earliest authored alignment, then existing corpus order.
- [ ] Complete-body and Selection copying retain original shortcode or Unicode bytes from raw storage. Editing and Submission remain unchanged.
- [ ] Verify selectors, flags, joiner sequences, compound skin tones, unknown and escaped names, mixed forms, and the forbidden double-consumption case.
- [ ] Verify exact navigation, full-emoji backgrounds, stable counts after resize, and allocation-failure cleanup through Presentation.
- [ ] Run `zig build test --summary all`.

## Contract

Use the [approved emoji presentation](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#emoji-and-literal-fallback), [emoji search rules](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#emoji-forms-identity-and-counts), and [pinned fixture research](../../m23-comment-thread-markdown-presentation-fixes/research/cloud-emoji-shortcodes.md).
Later or independent syntax tickets must use the shared conversion rules for their visible prose.
