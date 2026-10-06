# 08 — Present links, references, and image text

**What to build:** Show complete link and image destinations, including body-local reference destinations. Navigate search matches to their visible use and copy the required authored definitions.

**Blocked by:** 04 — Present inline Markdown styles.

**Status:** resolved

- [x] Show explicit links as `label ‹URL›` and images as `image: alt ‹URL›`. Show optional titles after destinations.
- [x] Keep complete destinations visible through wrapping in ReviewCards and Preview. Relative destinations retain authored text without an inferred base URL.
- [x] Apply inline styles and link underlines to supported label content. Keep code and destination bytes literal.
- [x] Resolve reference links and images within one body through case-insensitive names. The first matching definition wins.
- [x] Hide used definitions. Missing references and unused definitions remain literal and searchable.
- [x] Recognize bare HTTP and HTTPS URLs outside code. Exclude trailing sentence punctuation and unmatched closing brackets from the destination.
- [x] Keep product references literal. Do not acquire images or add product-reference navigation.
- [x] Both searches include labels, alternative text, destinations, and titles. Apply equal matching and ranking rules to labels and destinations.
- [x] Keep labels, destinations, and titles as separate matching regions. Generated image labels and URL brackets do not participate.
- [x] A resolved destination participates at each visible reference use. Two uses yield two Buffer Search occurrences without an extra hidden-definition occurrence.
- [x] Navigate destination matches to the visible use. Retain definition ranges separately from navigation coordinates.
- [x] Selection of a displayed reference destination copies the use's authored line and the matching definition's authored line.
- [x] A label-only selected row adds no unselected destination definition. Apply the same rule to reference images.
- [x] Copy required definitions once per typed owner, in authored order with touched body lines. Do not add intervening blank lines or unrelated definitions.
- [x] Verify complete destination wrapping, duplicate definitions, case-insensitive references, malformed links, punctuation, reference-use navigation, and exact-byte copying.
- [x] Run `zig build test --summary all`.

## Contract

Use the [approved link presentation](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#links-references-and-image-text), [reference search locations](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#authored-locations-and-reference-destinations), and [required hidden-line rules](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#required-hidden-lines).

## Implementation

ReviewBody separates link labels, destinations, titles, and generated image labels.
Destination text retains balanced brackets, relative paths, and literal shortcode bytes.
Malformed links and missing references retain their authored text.

Reference definitions use a body-local index with simple Unicode case folding.
The first matching definition supplies the destination and title.
Used definitions leave the reading projection.
Code definitions do not enter the index.

ReviewCards and Preview share complete destination wrapping.
Both searches retain visible-use coordinates and definition ranges separately.
Navigation reaches the first wrapped row that contains the match.
Match backgrounds apply only to the matched reference use and definition bytes.
Occurrence identity includes both sets of ranges.

Selection copies touched use lines and required definition lines through the existing typed-owner clipboard path.
Definitions follow authored order and copy once for each owner.
Label-only rows do not add unselected definitions.

## Review

The Standards review found unbounded scans through definitions and unmatched URL brackets.
The parser now indexes definitions and counts bracket balances once.
The stress check covers 2,048 definitions and 100,000 unmatched closing brackets.

The Spec review found match backgrounds shared between reference uses and lost emphasis around URL labels.
Regression checks confirmed both defects before the fixes.
A later review found that closed emphasis could remove a later destination's trailing delimiter byte.
The URL scanner now tracks active delimiter counts.
The final Standards and Spec reviews found no remaining findings.

## Verification

The approved seams cover ReviewBody, row projection, headless rendering, and Presentation Actions.
The checks cover both layouts and RemoteReview and LocalReview navigation.
Preview checks cover every built-in Theme.
Clipboard checks retain exact line endings, trailing spaces, first-definition ownership, and authored order.
Synthetic examples define project behavior rather than observed Cloud behavior.

The following commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target.

- `zig test src/tui/review_body.zig`. All 18 tests passed.
- `zig test --dep bbr -Mroot=src/tui/search.zig -Mbbr=src/root.zig --test-filter 'M23 links'`. All 9 tests passed.
- `zig build test-links --summary all`. All 17 tests passed.
- `zig fmt --check build.zig src tests`
- `zig build`
- `zig build test --summary all`. All 1,025 tests passed.

The first full-suite attempt exceeded the command timeout.
The final full-suite run used a longer limit and followed the code-review fixes.
