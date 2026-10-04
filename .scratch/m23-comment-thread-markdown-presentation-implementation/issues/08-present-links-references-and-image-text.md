# 08 — Present links, references, and image text

**What to build:** Show complete link and image destinations, including body-local reference destinations. Navigate search matches to their visible use and copy the required authored definitions.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** ready-for-agent

- [ ] Show explicit links as `label ‹URL›` and images as `image: alt ‹URL›`. Show optional titles after destinations.
- [ ] Keep complete destinations visible through wrapping in ReviewCards and Preview. Relative destinations retain authored text without an inferred base URL.
- [ ] Apply inline styles and link underlines to supported label content. Keep code and destination bytes literal.
- [ ] Resolve reference links and images within one body through case-insensitive names. The first matching definition wins.
- [ ] Hide used definitions. Missing references and unused definitions remain literal and searchable.
- [ ] Recognize bare HTTP and HTTPS URLs outside code. Exclude trailing sentence punctuation and unmatched closing brackets from the destination.
- [ ] Keep product references literal. Do not acquire images or add product-reference navigation.
- [ ] Both searches include labels, alternative text, destinations, and titles. Apply equal matching and ranking rules to labels and destinations.
- [ ] Keep labels, destinations, and titles as separate matching regions. Generated image labels and URL brackets do not participate.
- [ ] A resolved destination participates at each visible reference use. Two uses yield two Buffer Search occurrences without an extra hidden-definition occurrence.
- [ ] Navigate destination matches to the visible use. Retain definition ranges separately from navigation coordinates.
- [ ] Selection of a displayed reference destination copies the use's authored line and the matching definition's authored line.
- [ ] A label-only selected row adds no unselected destination definition. Apply the same rule to reference images.
- [ ] Copy required definitions once per typed owner, in authored order with touched body lines. Do not add intervening blank lines or unrelated definitions.
- [ ] Verify complete destination wrapping, duplicate definitions, case-insensitive references, malformed links, punctuation, reference-use navigation, and exact-byte copying.
- [ ] Run `zig build test --summary all`.

## Contract

Use the [approved link presentation](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#links-references-and-image-text), [reference search locations](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#authored-locations-and-reference-destinations), and [required hidden-line rules](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#required-hidden-lines).
