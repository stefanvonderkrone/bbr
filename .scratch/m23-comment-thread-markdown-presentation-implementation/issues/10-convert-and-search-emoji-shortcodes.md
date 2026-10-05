# 10 — Convert and search emoji shortcodes

**What to build:** Display known authored emoji shortcodes as their exact fixture Unicode bytes. Let either displayed Unicode or authored shortcode text find the same location without changing copied content.

**Blocked by:** 05 — Present and search joined paragraphs and headings. 06 — Present literal code blocks and Suggestions.

**Status:** resolved

- [x] Use the pinned Atlassian standard fixture's exact names and Unicode fallback bytes, including listed compound skin-tone names.
- [x] Retain the pinned source and applicable attribution with the shipped data. Describe the mapping as best-effort, not a complete Cloud catalog.
- [x] Match catalog names case-sensitively. Do not infer aliases, convert ASCII emoticons, or normalize Unicode.
- [x] Convert visible prose and link labels through the shared inline rules. The same rules apply to headings, lists, quotes, and table text when available.
- [x] Keep code, destinations, escaped names, and unknown names literal. Authored Unicode does not acquire an inferred shortcode.
- [x] ReviewCards and Preview use the same conversion and terminal-column measurements. Preserve compound sequences without fixed prototype width assumptions.
- [x] Both searches permit each converted emoji to supply either displayed Unicode or exact authored shortcode text within one match.
- [x] Allow different emoji to use different forms within one match. One emoji cannot supply both forms in sequence.
- [x] Permit shortcode substrings. Map either form to the complete authored shortcode or compound shortcode range.
- [x] Partial shortcode or Unicode matches emphasize the complete displayed emoji. Code points and terminal cells do not add occurrences.
- [x] Count and deduplicate by authored location. Keep leftmost non-overlapping Buffer Search behavior and the best Review Search match per region.
- [x] Apply M21 smart case, fuzzy scores, work limits, and deterministic ordering to legal representations.
- [x] Equal representations prefer displayed text, then earliest authored alignment, then existing corpus order.
- [x] Complete-body and Selection copying retain original shortcode or Unicode bytes from raw storage. Editing and Submission remain unchanged.
- [x] Verify selectors, flags, joiner sequences, compound skin tones, unknown and escaped names, mixed forms, and the forbidden double-consumption case.
- [x] Verify exact navigation, full-emoji backgrounds, stable counts after resize, and allocation-failure cleanup through Presentation.
- [x] Run `zig build test --summary all`.

## Contract

Use the [approved emoji presentation](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#emoji-and-literal-fallback), [emoji search rules](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#emoji-forms-identity-and-counts), and [pinned fixture research](../../m23-comment-thread-markdown-presentation-fixes/research/cloud-emoji-shortcodes.md).
Later or independent syntax tickets must use the shared conversion rules for their visible prose.

## Implementation

The source distribution retains the unchanged pinned fixture, its package attribution, and the full Apache 2.0 license.
A generator extracts the exact names and fallback bytes into the static catalog.
ReviewBody checks every fixture entry and nested variation against that catalog.

The shared inline parser converts prose and link labels into atomic spans.
ReviewCards and Preview retain each complete sequence and use the terminal measurement adapter.
Preview paints continuation-cell search backgrounds through the same range painter as ReviewCards.

Both searches follow separate Unicode and shortcode branches for each converted emoji.
Buffer Search deduplicates complete authored ranges before retaining leftmost non-overlapping occurrences.
Review Search keeps exact score and length frontiers within each legal representation's M21 work limit.
Its fallback retains the best score across legal greedy representations with query-bounded state storage.
Integer score units preserve mathematical ties before full authored-alignment comparison.

Presentation checks cover both layouts and RemoteReview and LocalReview.
They verify exact navigation, resize stability, Selection bytes, complete-body bytes, and worker allocation-failure cleanup.
These are project behavior checks, not live Cloud observations.

## Verification

- `zig test src/tui/review_body.zig` passed.
- `zig test --dep bbr -Mroot=src/tui/search.zig -Mbbr=src/root.zig` passed.
- `zig test --dep bbr -Mroot=src/tui/review_card.zig -Mbbr=src/root.zig --test-filter 'M23 emoji'` passed.
- `zig build test-emoji --summary all` passed all 19 tests.
- `zig build test-search-kernel test-authored-search test-links test-tables --summary all` passed all 182 tests.
- `zig fmt --check build.zig src tests` passed.
- `zig build` passed.
- `zig build test --summary all` passed all 1,052 tests on native Apple Silicon macOS with a macOS 15 minimum.

The initial full-suite command reached the shell's 120-second timeout during the version integration check.
The rerun with a 600-second timeout completed successfully.

## Review

The parallel Standards and Spec reviews found work-limit, fallback-score, and alignment-tie errors.
Regression tests cover every reported reproduction.
The final reviews report no open blockers.
The Standards fixes also remove repeated decoding and terminal-adapter dependencies from Presentation tests.
