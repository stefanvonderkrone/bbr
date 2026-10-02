# Choose search through Markdown projection

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 02, 04

## Question

How do Buffer Search and Review Search find and focus authored text after ReviewBody transforms its display?

The user accepts searches for both displayed emoji and authored shortcodes.
Choose whether this equivalence applies identically to Buffer Search and Review Search.
Define occurrence identity and counts when both forms name the same authored shortcode.
Define case behavior without changing the existing literal smart-case and fuzzy ranking contracts by accident.

Discuss hidden emphasis delimiters, escapes, inline code, list markers, links, images, and table presentation.
Define which generated text participates in search and how a hit focuses its exact authored owner and location.
Decide how shortcode hits highlight an entire displayed emoji, including multiple-code-point emoji.
Include wrapping, narrow terminals, collapsed ReviewCards, previews, and Session replacement.

Keep raw authored ranges available for editing and clipboard operations.
The answer defines matching and navigation semantics with observable acceptance examples.

## Comments

### Existing search contract

The session claimed this ticket after both dependencies reached `resolved`.
[M21 Buffer and Review Search](../../m21-buffer-review-search/SPEC.md) defines the existing search contract.
Buffer Search uses literal smart-case matching and leftmost, non-overlapping occurrences.
Review Search returns one best fuzzy match per logical authored line.
Both searches exclude generated text and retain exact authored ranges.
Formatting delimiters have zero width for matching.
Visible link destinations remain separate matching regions.
Search never crosses authored line endings, even when the display joins prose lines.
Buffer reprojection retains occurrence identity, but Session replacement expires it.

The search implementation builds both searches' ReviewBody candidates through `appendReviewBodyCandidates` in `src/tui/search.zig`.
It currently maps text slices back to equal-length authored slices.
Emoji conversion requires mapping displayed text to the complete authored shortcode range.
This is an implementation constraint, not a presentation decision.

### First search decision round

These recommendations await the user's answers.

1. Keep semantic text as the corpus for both searches.
   Include body text, code, link labels, image alternative text, displayed destinations, and optional titles.
   Exclude hidden delimiters, fence metadata, used reference definitions, and generated labels or markers.
   Treat generated separators as matching boundaries.
   Search a repeated table header once through its authored location.
2. Give converted emoji both displayed and authored matching forms in both searches.
   For example, prose `:mask:` matches `😷`, `:mask:`, and the substring `mask`.
   Keep code, destinations, escaped names, and unknown names literal.
   Do not infer a shortcode for an emoji authored directly as Unicode.
3. Keep smart case for text matching in both searches.
   Emoji conversion still uses case-sensitive catalog names.
   Thus `:MASK:` remains literal even though a lowercase text query can find its letters.
   Keep existing Unicode folding and fuzzy scoring rules.
4. Keep authored logical lines as matching boundaries.
   For authored `first` and `second` on separate ordinary paragraph lines, the display shows `first second`.
   A query for `first second` does not match across that authored line ending.
   Wrapping and width changes never add matches.
5. Show the formatted ReviewBody in Review Search previews, using the same presentation rules as ReviewCards.
   Keep positions tied to authored logical lines and Unicode scalar columns.
   Highlight the complete displayed emoji when any matched range belongs to its converted shortcode.

Occurrence counts, fuzzy representation selection, exact navigation, and compound emoji cases remain open for the next round.

### User answers to the first round

The user accepted the semantic corpus and generated-text exclusions.
The user accepted both matching forms for converted emoji and literal behavior in excluded conversion contexts.
The user asked how Telescope and ripgrep handle case without regular expressions.
The smart-case choice remains open until that explanation.

The user wants to explore matches across ordinary paragraph line breaks that display as spaces.
The recommendation to retain all authored line endings as matching boundaries was not accepted.
The next round must settle the matching unit and its boundaries.

The user accepted formatted Review Search previews and requires code-block Highlighting in those previews.
Preview code must use the agreed Grammar selection, literal content, backgrounds, fallback, and size limits.
The next round must settle preview eligibility within the shared Highlighting worker and retained-result budget.

### Case behavior reference facts

The session checked current upstream documentation and source on 2026-10-02.

- [ripgrep's guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md) documents `-F` for literal matching.
  With `-i`, matching ignores case.
  With `-S`, matching ignores case unless the query contains an uppercase letter.
  Without a case option or configuration override, ripgrep uses case-sensitive matching.
- [Telescope's defaults](https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/config.lua) pass `--smart-case` to ripgrep for grep pickers.
  Thus a lowercase literal query ignores case, but an uppercase query requires exact case.
- Telescope's default fuzzy sorter uses its [Lua fzy implementation](https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/algos/fzy.lua).
  That implementation lowercases both the query and candidate for matching, including uppercase queries.
  It uses original case for boundary bonuses.
  Native sorter extensions or user configuration can change these defaults.

M21 takes fuzzy scores from Telescope's fzy behavior but explicitly adds shared smart-case matching.
Matching rules and score bonuses are separate choices.
Keeping smart case follows Telescope's grep defaults, not its default Lua fuzzy case behavior.

### User answers to the second round

The user accepted smart case in both searches.
The user accepted matches across ordinary paragraph line breaks that Markdown joins with spaces.
Blank lines, explicit hard breaks, separate list items, table cells, code lines, and different bodies remain boundaries.
Review Search returns one best fuzzy match per paragraph region rather than per authored line of that paragraph.
Other matching regions retain their own boundaries.
The Presentation glossary now permits a ReviewBody Search Occurrence to span these authored lines.

The user accepted counts based on authored locations.
Matching either representation of one converted shortcode produces one occurrence.
Review Search keeps the best fuzzy match across the matching representations.
Highlight the complete displayed emoji rather than part of its shortcode or Unicode sequence.

The user accepted priority for code-block Highlighting in the selected Preview.
Reuse the shared worker, retained results, and limits from the code-block Highlighting decision.
Show readable plain code before the result arrives.
Search backgrounds preserve syntax colors.
This adds the selected Review Search Preview as an eligible presentation of a ReviewBody code block.
It does not add a second Highlighting worker or a separate result budget.

### Final edge-case decision round

These recommendations await the user's answers.

1. Allow each converted emoji in a query match to use either matching representation independently.
   Authored `:mask: :white_check_mark:` can match `😷 :white_check_mark:`.
   One emoji cannot supply both its displayed character and its shortcode in sequence for the same match.
   Thus `😷:mask:` does not match a body containing only one `:mask:`.
   Partial shortcode matches and matches within compound emoji highlight the complete converted emoji.
2. Keep each occurrence's complete authored ranges, including every matched logical line.
   Map a matched paragraph-join space to its authored line ending rather than to unrelated generated text.
   Show the first matched authored line and its one-based Unicode scalar column as the result position.
   Navigation lands on the first wrapped row containing the match.
   Buffer Search opens required disclosures temporarily.
   Opening a Review Search body result saves the required disclosure changes, as M21 already specifies.
   Resize, wrapping, table reprojection, and color arrival retain identity and counts.
   Raw clipboard and editing behavior remain governed by authored ranges and their existing contracts.
3. Keep the existing fuzzy scores and deterministic ordering on each legal matching representation.
   Choose the best calculation using the existing exact-before-fallback and score rules.
   If representations tie, prefer displayed text, then the earliest authored alignment.
   Keep generated separators as boundaries.
   Keep each visible link destination separate from its label and optional title.
4. Navigate a resolved reference-destination match to its visible reference use rather than the hidden definition.
   A destination resolved from a reference definition belongs to that reference use for search navigation and counts.
   Two authored reference uses produce two Buffer Search destination matches.
   Retain the definition's source ranges separately from the visible use's navigation coordinates.
   Its copied or edited bytes still come from the existing raw-body contract.

The ticket remains claimed until these choices and the complete shared understanding receive confirmation.

### User answers to the final edge-case round

The user accepted mixed emoji representations within one match.
One converted emoji cannot supply both representations in sequence to the same match.
Partial shortcode matches highlight the complete displayed emoji, including compound emoji.

The user accepted exact authored ranges across matched lines and navigation from the first matched authored position.
The user accepted the existing temporary Buffer Search disclosures and persistent disclosures after opening a Review Search body result.
Resize, wrapping, table reprojection, and Highlighting completion preserve occurrence identity and counts.

The user accepted existing fuzzy scores and deterministic ordering.
When matching representations tie, prefer displayed text, then the earliest authored alignment.
Link labels, destinations, and optional titles remain separate matching regions.

The user requires equal search support for link text inside `[]` and destination text inside `()`.
Neither region receives a special search priority merely because it is a label or destination.
The existing fuzzy score still ranks the quality of each match.
The session must confirm reference-destination navigation after explaining that both regions already participate in the semantic corpus.
The ticket remains claimed until the user confirms that remaining choice and closure.

### Final confirmation

The user confirmed equal search support for link labels and destinations.
The user confirmed navigation to the visible reference use for a resolved reference-destination match.
The user also confirmed closure of this decision.
The answer below supersedes earlier proposals where the user's choices differ.

## Answer

### Shared corpus and matching boundaries

Both searches use ReviewBody semantic text rather than terminal rows or complete raw Markdown.
Include prose, headings, list and quote text, table cell text, literal code, and Suggestion replacement code.
Include link labels, image alternative text, visible destinations, and optional titles.
Search label text inside `[]` and destination text inside `()` equally.
Neither region receives a special matching or ranking priority because of its role.

Exclude hidden emphasis and inline-code delimiters, recognized fence delimiters and metadata, and hidden used reference definitions.
Exclude generated heading markers, list markers and numbering, quote bars, table borders, image labels, and disclosure text.
Generated separators stop matches rather than connect unrelated authored text.
Link labels, destinations, and optional titles remain separate matching regions.
Literal fallback, unknown shortcodes, unused definitions, and unsupported Markdown remain searchable as visible authored text.
Hidden escape backslashes do not participate in matching.
Escaped punctuation remains literal searchable text.

Search an authored table header once, even when the narrow projection repeats that header beside several cells.
Resizing does not create extra Search Occurrences from generated table labels.
Keep the existing Buffer Search and Review Search scope rules from [M21 Buffer and Review Search](../../m21-buffer-review-search/SPEC.md).
Disclosure state does not remove otherwise eligible authored text from either corpus.
Buffer Search never starts File Enrichment.
Selected Version does not limit Review Search.

### Paragraph joins and matching units

Both searches can match across ordinary paragraph line breaks that Markdown displays as spaces.
For example, authored `first` and `second` on adjacent prose lines can match `first second`.
This is semantic paragraph joining, not terminal-width-dependent row matching.
Map a matched join space to the authored line ending.
Keep exact ranges for every matched authored line.

Blank lines, explicit hard breaks, separate list items, table cells, code lines, and different bodies remain boundaries.
Generated separators and separate link regions also remain boundaries.
Ordinary continuation lines within the same list-item or quote paragraph follow the same paragraph-join rule.
Wrapping never adds a matching boundary or removes a semantic boundary.

Buffer Search returns leftmost, non-overlapping literal matches in semantic corpus order.
Review Search returns one best fuzzy match per paragraph region instead of per authored line of that paragraph.
Text that Markdown does not join, including code, keeps its existing line-local matching unit.
A fuzzy match cannot cross any of the boundaries above.
Source File matching remains line-local in both searches.

### Emoji forms, identity, and counts

Give each converted emoji both its displayed Unicode form and its exact authored shortcode form for matching.
Apply this rule identically to Buffer Search and Review Search.
Permit substring matches in the shortcode form.
For example, prose `:mask:` matches `😷`, `:mask:`, and `mask`.

Each converted emoji can use either form independently within one query match.
Authored `:mask: :white_check_mark:` can match `😷 :white_check_mark:`.
One emoji cannot supply both forms in sequence to the same match.
Thus `😷:mask:` does not match a body containing only one `:mask:`.

Use the conversion catalog and contexts from [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md).
Code, destinations, escaped names, and unknown names remain literal.
Do not infer shortcodes for emoji authored directly as Unicode.
Do not invent aliases, remove variation selectors, or normalize Unicode sequences.

Map a match in either converted form to the complete authored shortcode range.
For a compound conversion, retain the complete compound shortcode range.
Partial shortcode matches and matches within compound Unicode sequences highlight the complete displayed emoji.
Multiple code points and terminal cells do not create additional occurrences.
Highlighting the complete emoji does not change its authored bytes.

Count and identify matches by their authored locations, not by the chosen matching form.
Matching both forms of the same converted shortcode yields one occurrence.
Different authored shortcode locations remain different literal occurrences.
Keep leftmost, non-overlapping Buffer Search behavior after mapping and deduplication.
Review Search retains the best match for its matching unit across the legal representations.

### Case and fuzzy ranking

Keep smart-case matching for both searches.
A query without uppercase ignores case through the existing simple Unicode case fold.
A query with uppercase requires exact case.
For example, `mask` matches literal `MASK`, but `MASK` does not match literal `mask`.

Conversion still uses case-sensitive catalog names.
Thus `:MASK:` stays literal even when a lowercase query finds its letters.
Keep the existing query validation, query length limit, and no-normalization contract.

Keep M21's fuzzy score rules, calculation limits, and deterministic ordering on each legal matching representation.
Use the existing exact-before-fallback and score rules to select the best calculation.
If representations tie, prefer displayed text, then the earliest authored alignment.
Keep the existing corpus-order rules for remaining ties.
Label and destination regions receive the same score rules.
Equal search support does not require unequal-quality matches to receive equal scores.

### Authored locations and reference destinations

A ReviewBody occurrence retains its Session Epoch, CommentId or TempId owner, and complete authored UTF-8 ranges.
It can span authored lines within one joined paragraph region.
Show the first matched authored line and its one-based Unicode scalar column as the result position.
Keep these coordinates independent of terminal columns, Reply indentation, and wrapping.

A resolved reference destination participates through each visible authored reference use.
Navigate its URL match to that visible use rather than the hidden definition.
Two authored reference uses produce two Buffer Search URL matches.
Retain the definition's source ranges separately from the visible use's navigation coordinates.
Do not create another occurrence for the hidden used definition itself.
An unused definition remains searchable literal authored text.

Search does not change storage, Composer content, or clipboard bytes.
Use [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md) for complete-body and mixed-Selection copying.
Search ranges do not replace that clipboard contract with a copy of transformed display text.

### Navigation, disclosure, and lifetime

Focus the exact authored owner and first wrapped row containing the first match range.
Highlight every projected part of a match across wrapping and paragraph joins.
Use the current Presentation Frame to resolve the location at the current width.
Never substitute an approximate owner or body line.

Keep the existing CommentScope, Reply inheritance, ScopeResolution, File focus, and Selected Version navigation rules.
Buffer Search opens required Thread and ReviewCard disclosures temporarily.
Restore saved disclosure state when the temporary reveal no longer applies.
Opening an authored Review Search result saves its required disclosure changes, as M21 already specifies.
Publish the exact destination Frame before closing the Overlay.

Resize, wrapping, table reprojection, disclosure changes, Theme changes, and color completion preserve occurrence identity and counts.
Body changes rebuild the relevant matching data through the existing search lifecycle.
Session replacement clears both searches and expires their occurrences.
Reject stale scan and Highlighting completions through the existing Session Epoch and content checks.
Preserve the prior complete Frame if matching or reprojection fails.

### Formatted Preview and code-block Highlighting

Review Search previews use the same formatted ReviewBody rules as ReviewCards.
Show matched semantic text with the agreed Markdown styles, emoji conversion, wrapping, and code backgrounds.
Keep positions tied to authored coordinates.
Search backgrounds preserve Markdown attributes and syntax foregrounds.

Apply code-block Highlighting in the selected Preview, including Suggestions.
Reuse GrammarMatch, authored Suggestion context, full-block analysis, fallback, and size limits from [Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md).
Show readable plain code first, then admit colors through the existing command and completion seam.
Color arrival does not change text, geometry, navigation, or occurrence identity.

The selected Preview makes its visible code blocks eligible even when their ReviewCard is collapsed or outside the viewport.
Give those eligible Preview blocks priority over other pending visible ReviewCard work.
Keep authored block order within that Preview.
Reuse a block's accepted result across Preview and ReviewCard presentations.
Treat visible Preview blocks as visible presentations for retained-result use and eviction.
Keep one shared worker and the existing 8 MiB retained-result budget.
Do not start Highlighting for every search result or add a separate Preview result budget.
Let already-started work finish before the worker takes the next eligible block.
Closing the Overlay or changing the selected result removes that Preview's pending eligibility.
Keep the existing stale-result rejection, failure states, retry triggers, and budget fallback.

### Acceptance examples

These examples define expected bbr behavior, not observed Cloud behavior.
Buffer Search counts literal occurrences.
Review Search retains one best fuzzy match per matching unit.

| Authored input or condition | Query or action | Expected result |
| --- | --- | --- |
| `**bold** text` | `bold text` | Match across hidden emphasis delimiters. Retain disjoint authored ranges. |
| `**bold**` | `**` | No match from hidden emphasis delimiters. |
| `\:mask:` | `:mask:` | Find literal shortcode text. Do not convert or infer an emoji match. |
| Prose `:mask:` | `😷`, `:mask:`, or `mask` | One occurrence at that authored shortcode. Highlight the complete displayed emoji. |
| Prose `:mask: :mask:` | `mask` | Two Buffer Search occurrences. One best Review Search match for the paragraph unit. |
| Prose `:mask: :white_check_mark:` | `😷 :white_check_mark:` | Match with independent forms for the two converted emoji. |
| Prose `:mask:` | `😷:mask:` | No match that consumes one converted emoji twice. |
| Prose `:thumbsup::skin-tone-2:` | `skin-tone-2` or `👍` | Map to the complete compound shortcode. Highlight all of `👍🏻`. |
| Authored Unicode `😷` | `:mask:` | No inferred shortcode match. |
| Inline or block code containing `:mask:` | `😷` | No conversion-equivalent match. `:mask:` and `mask` can match the literal code. |
| Literal `:MASK:` | `mask` | Match without conversion through smart case. |
| Literal `:mask:` | `MASK` | No exact-case match. |
| Adjacent ordinary prose lines `first` and `second` | `first second` | Match one joined paragraph region with exact ranges on both authored lines. |
| The same paragraph at different terminal widths | Resize | Keep occurrence identity, counts, and authored position. |
| `first` and `second` separated by a blank line or explicit hard break | `first second` | No match across the boundary. |
| Separate list items, table cells, or code lines containing `first` and `second` | `first second` | No match across the boundary. |
| A heading projected with `§2`, or an image projected with `image:` | Search only the generated marker or label | No generated-text occurrence. |
| A table whose narrow projection repeats a header | Search the header text | Count its authored header location once. |
| `[docs](https://example.invalid/)` | `docs` or `example.invalid` | Both regions participate equally. Navigate to the matching visible region. |
| Two reference uses of one URL definition | Buffer Search for the URL | Two visible-use occurrences. No extra hidden-definition occurrence. |
| An unused URL definition | Search its text | Find the literal authored definition. |
| A matched body hidden by Thread or ReviewCard disclosure | Buffer Search traversal | Open required disclosures temporarily and land at the exact owner and match. |
| The same hidden body | Open its Review Search result | Save required disclosure changes after the exact destination Frame exists. |
| A selected Preview with an eligible fenced code block | Inspect Preview | Show the agreed background and plain code immediately, then syntax colors when available. |
| A converted compound emoji or colored code at an active search match | Inspect match styling | Highlight the complete emoji or matched code cells without replacing syntax foregrounds. |
| A body match followed by code colors, wrapping, or table reprojection | Reproject | Preserve identity, counts, and authored ranges. |
| A search followed by successful Session replacement | Replace Session | Clear both searches and reject old completions. |

### Follow-up

[Validate combined Reply and Markdown presentation](./10-validate-combined-reply-and-markdown-presentation.md) can now proceed.
Its prototype must include joined-paragraph matches, complete emoji highlights, and code colors in Review Search Preview.
[Define the integrated M23 acceptance contract](./08-define-the-integrated-m23-acceptance-contract.md) must cover these changes to M21's line-local authored matching contract.
The implementation must use the complete authored ranges without assuming equal-length display and authored slices.
This ticket resolves the search decision and does not implement M23.
