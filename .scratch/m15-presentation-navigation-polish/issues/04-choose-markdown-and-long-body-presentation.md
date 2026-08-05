# Choose Markdown and long-body presentation

Type: prototype
Status: resolved
Blocked by: 03

## Question

How should Comment and Draft Markdown, fenced Suggestions, links, headings, emphasis, and pathological body lengths render and disclose in the DiffPane without breaking row ownership, navigation, or terminal readability?

## Answer

Adopt the prototype's **B — Bounded review cards** contract with a default collapsed threshold of **six rendered body rows**.

- Render every Comment and Draft as one bounded card within its existing DiffPane position. The header keeps the published/draft/suggestion marker, author or `you`, and secondary metadata visually separate; the body sits below it. Root Comments, Replies, root Drafts, and reply Drafts retain their existing indentation and ordering, but adjacent items no longer share one uninterrupted color band.
- Interpret Markdown only for presentation. Review and persistence keep the authored body byte-for-byte; malformed or unsupported syntax degrades to literal text and never hides content. Render headings as strong section rows, emphasis with terminal emphasis, strong text with brighter/bold styling, and links as a styled label followed by a visible `‹destination›` so the target remains discoverable without mouse or OSC 8 support.
- Treat a fenced `suggestion` block as a semantic code block inside the card. Keep its contents literal—never parse Markdown inside the fence—and use the existing Suggestion Theme role plus a `suggestion` label and code-oriented rows. Preserve prose before and after the fence. An unclosed fence degrades to literal body text rather than swallowing following review content.
- Collapse a body only when its projected content exceeds the configured limit, defaulting to six rendered body rows. The budget counts terminal display rows after wrapping, not Markdown source lines or bytes. Keep the card header and the first complete semantic blocks that fit; never split a heading or fenced block merely to fill the sixth row. The persistent footer reports both hidden and total rendered rows, for example `▸ 8 hidden rows · 14 total · enter to expand`.
- `Enter` on any Buffer row owned by a collapsible card toggles that body's expansion; the footer is itself a navigable row with the same owner. Expanding preserves the card header and inserts all projected body rows in place; re-collapsing returns to the same card rather than jumping elsewhere. Ordinary Motions remain Buffer-row based—the prototype's item-at-a-time `j`/`k` was only an evaluation convenience.
- Keep expansion independent per body and Session-relative, keyed by a tagged stable identity: published Comment by `CommentId`, Draft by `TempId`. Preserve it across redraws, terminal resizes, Buffer rebuilds, File isolation, Draft saves, and File Enrichment; clear it on successful Session replacement. A resize may change the rendered-row counts and whether a non-expanded body crosses the threshold, but it does not change identity or discard an explicit expanded state.
- Give card header, body, code block, Suggestion, footer, focus, and link treatments explicit Theme composition rather than embedding colors in Markdown parsing. At narrow widths, preserve the item marker and disclosure count before truncating secondary metadata; body text wraps within the card instead of widening or horizontally scrolling the DiffPane.

Prototype context: branch `prototype/m15-markdown-long-body`, commit `94429a9`, path `.scratch/m15-presentation-navigation-polish/prototypes/markdown-long-body/`.

## Comments

- 2026-08-04: Interactive Markdown and long-body prototype prepared with Continuous rendered flow, Bounded review cards, and Source-faithful outline variants. It exercises headings, emphasis, visible link destinations, fenced Suggestions, independent expansion, and six/eight/twelve-row thresholds. Captured on branch `prototype/m15-markdown-long-body` at commit `94429a9`.
- 2026-08-04: Human selected B — Bounded review cards with a six-row default threshold.
