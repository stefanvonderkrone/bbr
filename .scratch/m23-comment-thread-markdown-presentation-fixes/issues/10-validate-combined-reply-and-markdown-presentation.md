# Validate combined Reply and Markdown presentation

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:prototype
Type: prototype
Status: resolved
Blocked by: 03, 04, 05, 06

## Question

Do the agreed Reply and ReviewBody rules remain readable together at narrow widths, or which rules need revision before acceptance?

Use `prototype` to make a small terminal presentation example for the human to review.
Use `domain-modeling` and the Presentation and Review glossaries for its terms.
Link the prototype as an asset rather than paste it into this ticket.

Combine these decisions:

- [Choose nested Reply presentation](./03-choose-nested-reply-presentation.md).
- [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md).
- [Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md).
- [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md).

Show published and Draft ancestry with both ordinary and capped Reply indentation.
Include headings, nested lists, quotes, literal code, emoji, and a table that changes to header-labelled cells.
Include combined bold, italic, link, and inline-code styles with cursor, Selection, and search backgrounds.
Use the human review checklist in the Markdown presentation decision to select representative combinations.

Compare available body widths below 40 columns and at 40, 60, 80, and 100 columns.
Include a resize and a ReviewCard disclosure change.
Include a search match across joined prose lines and a complete compound-emoji highlight.
Show formatted Review Search Preview with code-block Highlighting and search backgrounds that preserve syntax foregrounds.
Compare a light Theme with a dark Theme to check the agreed code-background direction.

Resolve through the human's reaction to the examples.
Record whether the combined rules stand or which presentation decisions need revision.
Link any revised decision before the integrated acceptance contract proceeds.

This is a planning prototype, not application implementation.
The human-authored test PullRequest Comments and post-implementation review remain a separate acceptance requirement.

## Comments

### Prototype ready for human review

Open the [combined presentation prototype](../prototype/combined-presentation.html) in a browser.
The single HTML file needs no server or dependencies.

The prototype contains three views:

- The combined Thread shows contiguous parent subtrees and published-first sibling order.
  Its ordinary example follows Root, A, C, F, D, B, E, H.
  Its deep example has ten published Replies followed by ten Draft Replies.
  Both examples retain typed owners and authored parent relationships.
- The style combinations show Markdown attributes with cursor, Selection, and search background swatches.
  The code examples include syntax foregrounds, plain fallback, and a distinct Suggestion surface.
- The formatted Review Search Preview shares the ReviewBody example and code-color control.

Compare root body widths of 32, 40, 60, 80, and 100 terminal columns.
The resize control also covers widths from 20 through 110 columns.
The current four-column ReviewCard inset makes the DiffPane four columns wider than the root body.
The state display shows the indentation unit, indentation budget, and table-fit threshold.
The width table compares the depth-20 case at all five requested widths.

Change between the light and dark Theme examples.
Collapse the root ReviewCard body and use the temporary Buffer Search reveal control.
Replies remain visible when only the root body collapses.
Select the joined-paragraph, compound-emoji, and literal-code search examples.
Switch syntax colors off and on to compare plain code with color arrival.

This is a hand-built presentation example, not a Markdown parser or application implementation.
Search matches and syntax foregrounds are fixed examples.
The background swatches check composition, not Action availability.
Existing Buffer Search requires a cleared Selection.
The six-row disclosure budget illustrates a disclosure change without setting a new M23 limit.
The browser assigns two cells to the example emoji.
The later bbr review must check actual terminal fonts, Theme colors, and attribute support.

### Prototype checks

The browser check covered 72 combinations of width, ancestry, and view.
Widths included 20, 32, 40, 55, 56, 60, 75, 76, 80, 95, 96, and 100 columns.
Every projected row retained the expected DiffPane column count.
The check also verified subtree order, typed owners, list continuation alignment, and temporary body reveal.
The compound emoji occupied one complete two-cell search highlight.
Dark code backgrounds were lighter than their ReviewCard backgrounds.
Light code backgrounds were darker than their ReviewCard backgrounds.
The browser reported no console errors during these checks.

The human's reaction and confirmation remain open.
Keep this ticket claimed until the human accepts the combined rules or identifies required changes.

### Human confirmation

The user reviewed the prototype and replied, "looks good".
The user accepted the combined presentation without requesting changes.

## Answer

The [combined presentation prototype](../prototype/combined-presentation.html) is accepted for this planning decision.
Keep the combined Reply and ReviewBody rules from these decisions:

- [Choose nested Reply presentation](./03-choose-nested-reply-presentation.md).
- [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md).
- [Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md).
- [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md).

No presentation decision needs revision because of this review.
The prototype remains a planning asset with fixed semantic examples, search matches, and syntax foregrounds.
Its representative colors, two-cell emoji, and six-row disclosure budget do not add new application requirements.
Its background swatches do not change Action availability.

The human-authored test PullRequest Comments and post-implementation bbr review remain required.
Use the [human review checklist](./04-choose-reviewbody-markdown-presentation.md#human-review-checklist) for that acceptance review.
The planning prototype does not establish observed Cloud compatibility or replace application acceptance checks.

This resolution exposes no new decision ticket or change to the map's scope.
[Define the integrated M23 acceptance contract](./08-define-the-integrated-m23-acceptance-contract.md) can now proceed.
