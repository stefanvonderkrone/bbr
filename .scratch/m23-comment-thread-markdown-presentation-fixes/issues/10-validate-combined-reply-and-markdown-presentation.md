# Validate combined Reply and Markdown presentation

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:prototype
Type: prototype
Status: needs-info
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
Compare a light Theme with a dark Theme to check the agreed code-background direction.

Resolve through the human's reaction to the examples.
Record whether the combined rules stand or which presentation decisions need revision.
Link any revised decision before the integrated acceptance contract proceeds.

This is a planning prototype, not application implementation.
The human-authored test PullRequest Comments and post-implementation review remain a separate acceptance requirement.
