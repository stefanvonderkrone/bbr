# Choose ReviewBody Markdown presentation

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 01, 02, 09

## Question

How does ReviewBody present the selected Markdown guide in a terminal, accounting for verified Cloud differences?

Apply [Choose Cloud compatibility and evidence policy](./09-choose-cloud-compatibility-and-evidence-policy.md) to syntax scope and evidence requirements.
Give explicit project behavior and acceptance examples for cases that Cloud evidence does not settle.

Define the supported syntax and literal fallback for malformed or unsupported input.
M23 requests turquoise italic text, orange bold text, and green inline code with formatting delimiters hidden.
Choose Theme handling and precedence for combined styles, links, headings, and cursor or search emphasis.

Choose heading markers, paragraph spacing, list markers, numbering, nesting, and continuation indentation.
Choose terminal representations for quotes, strikethrough, tables, images, and reference links from the target guide.
Choose behavior for automatic links and product-specific references after compatibility research.
Image representation does not yet imply image acquisition or a terminal image protocol.

Choose the emoji catalog boundary and conversion contexts from the shortcode research.
Unknown shortcodes remain authored text. Code text remains literal.
Keep authored bytes separate from displayed text and preserve source ownership across wrapping and disclosure.

Link prototypes if the human needs concrete terminal examples.
The answer defines presentation behavior and acceptance examples, not a parser implementation.

## Comments

### First presentation decision round

The session claimed this ticket after all three dependencies reached `resolved`.
The following recommendations await the user's answers.
They are project proposals, not observed Cloud behavior.

1. Use Theme roles for italic, bold, and inline code.
   Their default colors are turquoise, orange, and green.
   Combined bold and italic text uses orange with both attributes.
   Inline code keeps its green foreground inside emphasis.
   Cursor, Selection, and search emphasis retain priority where their styles conflict.
2. Show heading levels through compact generated markers.
   Use one blank row between paragraphs and two spaces for each nested list level.
   Wrapped list text aligns with its item text.
   Normalize unordered markers to bullets.
   Ordered lists start at the first authored number and then increment.
3. Show quotes with a vertical bar for each quote level.
   Show strikethrough with the terminal's strikethrough attribute.
   Show aligned tables when they fit.
   At narrow widths, show each table row as a sequence of header-labelled cells.
4. Show link labels with their complete destinations.
   Resolve reference links from body-local definitions.
   Show images as an image label, alternative text, and destination.
   Keep product references as authored text unless an explicit Markdown link supplies a destination.
5. Use the pinned Atlassian standard emoji fixture as a best-effort catalog.
   Keep its exact shortcode names and Unicode fallback bytes, including listed skin variations.
   Do not invent aliases or convert ASCII emoticons.
   Convert visible prose and link labels.
   Keep code, destinations, unknown names, and escaped shortcodes literal.
6. Hide valid fence delimiters and show code in a distinct block.
   Preserve code text after removal of structural container indentation.
   Keep language directives such as `#!python` as code text.
   Decide exact fence recognition after this presentation choice.
7. Keep malformed or unsupported constructs as visible authored text.
   Limit literal fallback to the affected construct rather than the complete body.
   Keep authored HTML visible as text.

Exact syntax boundaries, marker choices, unsupported terminal attributes, and conversion edge cases remain open for later rounds.

### User answers to the first round

The user accepted the starting recommendations for Theme roles, structural presentation, quotes, strikethrough, tables, emoji, and literal fallback.
The user also accepted hidden code fences and literal code content.
The user requires a distinct background color for code blocks.

The accepted Theme proposal uses turquoise italic text, orange bold text, and green inline code by default.
Combined bold and italic text uses orange with both attributes.
The exact composition with other styles remains open.

The accepted structural proposal uses compact heading-level markers, one blank row between paragraphs, bullets, and two-space displayed list nesting.
Ordered lists start at the first authored number.
The exact heading markers, authored list indentation, and numbering edge cases remain open.

The user asked what product references mean before deciding the link proposal.
The session explained `pull request #1541` and Jira key `ABC-123` as examples.
Their destinations depend on Repository or integration context.
The recommendation to retain these shortcuts as literal text awaits the user's answer.

The user requires example Comments authored by a human for human review.
The location and review stage remain open.

The ticket remains claimed because exact syntax and presentation decisions remain open.

### User answers to the second round

The user accepted literal product references in M23.
The user requested a new milestone to investigate navigation to a reference or a preview.
[M31 Product reference navigation and preview investigation](../../../TODO.md) records that follow-up outside M23.

The user accepted these presentation rules:

- Headings use `§1 Title` through `§6 Title`, with bold heading text and hidden authored delimiters.
- Each nested list level uses four authored spaces and two displayed spaces.
  Wrapped text aligns with the list item's text.
- Code blocks use a distinct Theme background.
  The user corrected the proposed direction.
  Dark Themes use a lighter code background, and light Themes use a darker code background.
  Suggestions retain their distinct background and label.
- Backtick and tilde fences work at the root and inside lists or quotes.
  A closing fence uses the opening character and at least the opening fence length.
  An unclosed fence remains literal text.
- Ordinary paragraph line breaks become spaces.
  Two trailing spaces create a visible line break.
- Emoji names match case-sensitively and use the fixture's exact Unicode fallback bytes.
  Listed compound skin-tone names are supported.
  Guessed aliases and ASCII emoticon conversion are excluded.
- A human authors example Comments in an agreed test PullRequest.
  A human reviews their presentation in bbr after implementation.
  This is an implementation acceptance requirement, not work to execute during this map.

The next round must settle style composition, remaining syntax boundaries, table edge cases, and link display details.

### Third presentation decision round

These recommendations await the user's answers:

1. Use this foreground precedence: inline code, bold, italic, then ordinary text.
   Keep link underlines and combine applicable text attributes.
   Cursor, Selection, and search change backgrounds rather than Markdown foregrounds.
   Do not make complete Draft bodies bold merely because they are Drafts.
   If the terminal cannot show strikethrough, show the authored `~~text~~` delimiters.
2. Increment ordered list numbers from the first authored number.
   For example, authored `4. A` followed by `1. B` displays `4. A` and `5. B`.
   Accept digit-plus-period markers, but keep `1)` literal.
   Require a blank line before a list after prose or a switch between sibling list types.
3. Support ATX and Setext headings.
   Support both asterisk and underscore emphasis forms.
   Keep intraword underscores such as those in `snake_case_name` literal.
4. Use table separator alignment when the complete table fits.
   Protect escaped pipes and pipes inside inline code from cell splitting.
   Treat missing cells as empty.
   Show a row with extra cells literally rather than discard its content.
5. Show links as `label ‹URL›` and images as `image: alt ‹URL›`.
   Show an optional title after the destination.
   Resolve reference names case-insensitively, using the first definition.
   Hide used definitions.
   Keep missing references and unused definitions literal.
6. Recognize bare HTTP and HTTPS URLs outside code.
   Exclude trailing sentence punctuation and unmatched closing brackets from the link.
   Keep relative destinations visible exactly as authored without guessing a base URL.
7. Keep code spaces and tabs, removing only structural container or code-block indentation.
   Wrap long code lines without discarding content.
   Display tabs at four-column stops measured from the code content origin.
   Keep inline-code content literal, including whitespace.
8. Hide a backslash that escapes punctuation and suppress parsing of that escaped punctuation.
   For example, `\:mask:` displays literal `:mask:`.
   Keep authored HTML tags and entity spellings visible as text.

### User answers to the third round

The user accepted the style, list, heading, emphasis, table, link, URL, escape, and HTML proposals.
The user accepted code whitespace preservation, structural indentation removal, long-line wrapping, and literal inline code.
The user asked what four-column tab stops mean.
The session explained that a tab advances to the next multiple of four terminal columns from the code content origin.
For example, `a<TAB>b` displays as `a   b`, and `abcd<TAB>e` displays as `abcd    e`.
The authored tab remains unchanged in storage and clipboard output.
The tab-stop rule awaits confirmation after this explanation.

The user requires format combinations in the human review checklist.
The user requested a separate milestone to explore image rendering.
[M32 ReviewBody image rendering investigation](../../../TODO.md) records that follow-up outside M23.

### Human review checklist

A human authors the example Comments in an agreed test PullRequest.
A human reviews their presentation in bbr after implementation.
The checklist guides that review without replacing automated acceptance checks.

- [ ] Review bold and italic in both nesting orders.
  The text uses orange with both attributes.
- [ ] Review inline code inside bold and italic text.
  The inline-code foreground stays green.
  The code text remains literal.
- [ ] Review bold and italic link labels, separately and together.
  The link underline remains visible with the selected Markdown foreground and attributes.
- [ ] Review strikethrough combined with bold, italic, and links.
  If the terminal cannot show strikethrough, its authored delimiters stay visible.
- [ ] Review headings that contain italic text, links, and inline code.
  The heading level marker stays visible.
  Foreground precedence follows the agreed style rules.
- [ ] Review converted emoji inside bold, italic, and link labels.
  Include listed compound skin-tone names, unknown names, escaped names, and shortcodes inside code.
- [ ] Review each format combination under the cursor, in a Selection, and at a Search Occurrence.
  Include combinations where these interaction backgrounds overlap.
  Markdown foregrounds and text attributes remain intact.
- [ ] Review code blocks with cursor, Selection, and search backgrounds.
  Dark Themes use lighter code backgrounds, and light Themes use darker code backgrounds.
  Suggestions retain their distinct background and label.
- [ ] Review plain prose and each format combination in published Comments, Replies, Drafts, and Draft Replies.
  Draft body text is not bold merely because its owner is a Draft.
- [ ] Review nested lists and quotes containing links, inline code, and fenced code.
  Check wrapped continuation alignment and narrow Reply body widths.
- [ ] Review wide and narrow tables containing emphasis, links, inline code, and emoji.
  Check escaped pipes, code pipes, missing cells, and rows with extra cells.
- [ ] Review images with alternative text, destinations, and optional titles.
  M23 shows the text representation rather than acquiring the image.
- [ ] Resize examples and expand or collapse their ReviewCards.
  Check the format combinations across light, dark, and system Themes.
- [ ] Copy formatted examples and inspect the authored Markdown.
  Storage and clipboard output retain the agreed raw-body and Selection contracts.

The ticket remains claimed until the tab-stop rule and shared understanding are confirmed.

### Final confirmation

The user confirmed four-column tab stops after the explanation.
The user also confirmed closing this presentation decision.

## Answer

### Scope and evidence

M23 uses best-effort support for the selected guide's syntax.
Apply [Choose Cloud compatibility and evidence policy](./09-choose-cloud-compatibility-and-evidence-policy.md) when Cloud evidence differs from the guide.
The rules below define bbr behavior where that evidence does not settle a case.
Their acceptance examples are project decisions, not live Cloud observations.

Support headings, paragraphs, emphasis, strikethrough, lists, quotes, inline code, indented code, fenced code, links, images as text, and tables.
Cloud-only extensions excluded by the compatibility decision remain literal.
Product references also remain literal in M23.

### Theme and style composition

Theme roles control Markdown colors.
Their defaults are turquoise for italic text, orange for bold text, and green for inline code.
Hide valid authored emphasis and inline-code delimiters.
Use both asterisk and underscore emphasis forms.
Keep intraword underscores such as those in `snake_case_name` literal.

Foreground precedence is inline code, bold, italic, then ordinary text.
Combine applicable bold, italic, and strikethrough attributes.
Keep link underlines when Markdown styles combine with links.
Bold and italic together use orange with both attributes.
Inline code inside emphasis uses green and retains its literal content.

Cursor, Selection, and search emphasis change backgrounds rather than Markdown foregrounds.
Keep their existing interaction behavior while preserving applicable text attributes.
A Draft's ownership does not make its complete body bold.
Draft identification still uses its ReviewCard header and role styling.

Use the terminal's strikethrough attribute for `~~text~~`.
If that attribute is unavailable, show the authored strikethrough delimiters.

### Headings, paragraphs, lists, and quotes

Support ATX headings and Setext headings.
Show a generated `§1` through `§6` marker for the heading level.
Make heading text bold and apply the agreed foreground precedence to its inline content.
Hide the authored heading delimiters.

Use one blank row between paragraphs.
Join ordinary paragraph line breaks with spaces.
Two trailing spaces create a visible line break.

Normalize unordered list markers to bullets.
Accept digit-plus-period ordered markers.
Start numbering at the first authored number and increment for each later item in that list.
Keep `1)` literal.
Require a blank line before a list after prose and between different sibling list types.

Use four authored spaces for each nested list level.
Use two displayed spaces for each nested list level.
Align wrapped continuation text with its item's text rather than its marker.
Support ordered and unordered child lists within either parent type.

Show a vertical bar for each quote level.
Lists and code inside quotes retain their own presentation rules.
These body offsets apply within the ReviewCard width established by [Choose nested Reply presentation](./03-choose-nested-reply-presentation.md).

### Code blocks and whitespace

Support indented code and backtick or tilde fences.
Fences work at the root and inside lists or quotes.
An opening fence uses at least three backticks or tildes.
A closing fence must use the same character and at least the opening fence length.
Hide recognized fence delimiters.
An unclosed fence stays literal rather than consuming the remaining body as formatted code.

Show code blocks with a distinct Theme background.
Dark Themes use a lighter code background, and light Themes use a darker code background.
Suggestions retain their distinct background and label.
[Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md) decides syntax foregrounds, Grammar selection, and Highlighting fallback.

Remove only structural container or code-block indentation.
Keep code content literal, including whitespace, shortcodes, Markdown characters, HTML, and language directives such as `#!python`.
Wrap long code lines without discarding content.
Keep inline-code content literal, including whitespace.

A displayed tab advances to the next multiple of four terminal columns from the code content origin.
Reply, list, quote, and ReviewCard indentation do not change that origin.
The authored tab remains unchanged in storage and clipboard output.

### Tables

Recognize a table through its header and separator rows.
Apply separator alignment and inline formatting to its cells.
Escaped pipes and pipes inside inline code do not split cells.
Treat missing cells as empty.
Show a row with extra cells literally rather than discard its content.

Show an aligned table when the complete table fits the available body width.
At narrow widths, show each row as a sequence of header-labelled cells.
Wrap the cell text within the available width.
Resizing changes the projection without changing the authored table or its owner.

### Links, references, and image text

Show explicit links as `label ‹URL›`.
Show images as `image: alt ‹URL›`.
Show an optional title after the destination.
Keep the complete destination visible through wrapping.
M23 does not acquire or render the image itself.

Resolve reference links and reference images from definitions in the same body.
Match reference names without case sensitivity.
The first matching definition wins.
Hide used definitions from the reading projection.
Keep missing references and unused definitions literal.

Recognize bare HTTP and HTTPS URLs outside code.
Exclude trailing sentence punctuation and unmatched closing brackets from the link.
Keep relative destinations visible exactly as authored without guessing a base URL.
Do not convert emoji shortcodes inside destinations.

Keep product shortcuts such as `pull request #1541` and `ABC-123` literal.
Their destinations require Repository or integration context.
[M31 Product reference navigation and preview investigation](../../../TODO.md) covers the requested follow-up.
[M32 ReviewBody image rendering investigation](../../../TODO.md) covers image acquisition and terminal image presentation.

### Emoji and literal fallback

Use the pinned Atlassian standard emoji fixture from [Bitbucket Cloud Comment emoji shortcodes](../research/cloud-emoji-shortcodes.md).
Keep its exact shortcode names and Unicode fallback bytes, including listed compound skin-tone names.
Use case-sensitive matching.
Do not invent aliases or convert ASCII emoticons.
This is a best-effort catalog, not a claim of complete Cloud support.

Convert visible prose and link labels.
Keep code, destinations, unknown names, and escaped shortcodes literal.
Apply the same visible-prose rule to heading, list, quote, and table text.

Hide a backslash that escapes punctuation and suppress parsing of that escaped punctuation.
For example, `\:mask:` displays literal `:mask:`.
Keep authored HTML tags and entity spellings visible as text.

Malformed or unsupported input falls back to visible authored text for the affected construct.
Do not make the complete body literal merely because one construct is malformed.
Literal fallback does not discard the affected text.

### Authored content and source ownership

Review retains the exact authored bytes.
Formatting, numbering, emoji conversion, tab expansion, wrapping, and generated labels are Presentation projections.
They do not change authored Comment or Draft content.

Keep the CommentId or TempId owner and authored source ranges available across wrapping and disclosure.
Generated text does not replace authored text for editing or copying.
Use [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md) for complete-body and mixed-Selection copying.
[Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) decides transformed matches, hidden text, and Search Occurrence locations.

### Acceptance examples

These examples define expected bbr behavior.
They do not claim Cloud equivalence.

| Authored input or condition | Expected presentation |
| --- | --- |
| `*italic*` and `_italic_` | Turquoise italic text without the emphasis delimiters. |
| `**bold**` and `__bold__` | Orange bold text without the strong-emphasis delimiters. |
| `**bold and _italic_**` | Orange throughout, with italic also applied to `italic`. |
| ``**`*literal* :mask:`**`` | Green literal inline-code content with the outer bold attribute. |
| `snake_case_name` | The underscores remain visible. |
| `## Title` | `§2 Title`, with bold heading text. |
| `Title` followed by a Setext `===` underline | `§1 Title`, without the underline. |
| `first` followed by an ordinary line break and `second` | `first second`. |
| `first` followed by two trailing spaces and a line break | A visible line break before the next text. |
| `4. A` followed by `1. B` in the same list | `4. A`, then `5. B`. |
| A child list indented by four authored spaces | Two displayed nesting spaces, with wrapped text aligned under the item text. |
| `1) A` | Literal text rather than an ordered item. |
| `> quoted` | A quote bar followed by `quoted`. |
| A valid backtick or tilde block containing `:mask:` and `#!python` | Literal content on the distinct code background, with hidden fences. |
| `before`, then an unclosed fence | The fence and affected text stay literal. Earlier valid prose keeps its formatting. |
| `a<TAB>b`, where `<TAB>` is an authored tab | `a   b`. |
| `abcd<TAB>e`, where `<TAB>` is an authored tab | `abcd    e`. |
| A table cell containing an escaped pipe or a pipe inside inline code | The pipe stays within that cell. |
| A row with fewer cells than the header | Empty cells fill the missing positions. |
| A row with more cells than the header | That row stays literal without losing its extra cells. |
| A table that does not fit its Reply body width | Header-labelled cells replace the aligned table projection. |
| `[docs](https://example.invalid/)` | `docs ‹https://example.invalid/›`, with link underline. |
| `[docs](https://example.invalid/ "Guide")` | `docs ‹https://example.invalid/› "Guide"`. |
| `[Docs][ID]` with a body-local `[id]: https://example.invalid/` definition | The reference resolves and its used definition hides. |
| A missing reference or an unused definition | Literal authored text. |
| `![diagram](images/diagram.png)` | `image: diagram ‹images/diagram.png›`, without guessing a base URL. |
| `https://example.invalid/path.` | The URL links, but the final sentence period is outside the link. |
| `pull request #1541` or `ABC-123` | Literal product reference text. |
| `:white_check_mark:` and `:mask:` in prose | `✅` and `😷` using the fixture mappings. |
| `:thumbsup::skin-tone-2:` | `👍🏻` using the fixture's compound mapping. |
| `:MASK:` or an unknown name | Literal authored shortcode text. |
| `\:mask:` | Literal `:mask:`, without emoji conversion. |
| `https://example.invalid/:mask:` | The destination keeps its authored shortcode bytes. |
| `<tag>` and `&amp;` | Visible authored tag and entity spellings. |
| Plain prose in a Draft | Ordinary body weight rather than ownership-induced bold. |
| Styled text under cursor, Selection, or search emphasis | Interaction backgrounds preserve the Markdown foreground and applicable attributes. |

### Human review and follow-up

A human authors example Comments in an agreed test PullRequest.
A human reviews their presentation in bbr after implementation.
Use the [human review checklist](#human-review-checklist) above, including format and interaction-background combinations.
This acceptance review does not happen during the planning map.

The combined layout is now specific enough for a planning prototype.
Use [Validate combined Reply and Markdown presentation](./10-validate-combined-reply-and-markdown-presentation.md) before the integrated acceptance decision.
The prototype does not replace the post-implementation human review.
