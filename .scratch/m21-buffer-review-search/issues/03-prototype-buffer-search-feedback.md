Type: prototype
Status: resolved
Blocked by: 02

# Prototype Buffer Search Feedback

## Question

What is the clearest Buffer Search prompt, match highlight, active-match highlight, and count presentation in the existing DiffPane?

Build a cheap interactive prototype for normal, no-match, wrapped, SideBySide, hidden-match, and narrow-terminal cases. The prototype must preserve existing diff, syntax, emphasis, cursor, and Selection styles well enough for the human to compare them.

## Comments

- Interactive prototype: [Buffer Search Feedback](../prototype-buffer-search-feedback.html).

## Answer

The human selected variant A, the command-line presentation.

### Prompt and count

Buffer Search uses the bottom status line for query input. It does not cover the DiffPane or replace the DiffPane title.

- The left side shows an accent-colored `/` followed by the query in the normal foreground color.
- The right side shows `active/total`, such as `1/8`. The count uses no label.
- A query with no Search Occurrence shows `0/0` in the Theme's error color. This is the complete incremental no-match feedback.
- The query field takes the space between the prompt and the count. If the text is too long, it keeps the query end visible because input only appends at the end.
- If the terminal cannot fit both the query prompt and the count, Presentation hides the count first. It never hides the `/` or the query end.

After Enter accepts the query, the normal status text returns on the left. The accepted query count remains on the right. A wraparound or no-match message replaces only the left status text, so the count remains visible.

### Match styles

The Theme supplies `search_match`, `search_active`, and `search_no_match` styles. Every built-in Theme must keep both match styles distinct from its diff, cursor, Selection, Comment, and Draft styles.

- `search_match` uses a muted ochre background. It keeps the cell's existing foreground and text attributes, including syntax color.
- `search_active` uses a bright orange background with a dark, bold foreground. It takes priority over `search_match` and the cell's base style.
- Search styles apply only to matched cells. Diff, emphasis, cursor, Selection, Comment, and Draft styles remain visible on every other cell in the row.
- If one Search Occurrence crosses wrapped visual rows or several ReviewBody ranges, every covered cell uses the same match style. The count still includes one Search Occurrence.
- A SideBySide shared context Search Occurrence can highlight both projections. The count includes it once.

The active Search Occurrence needs no extra row marker. Its bright matched cells and the existing highlighted DiffPane row provide both location signals.

### Hidden and narrow content

Temporary search reveal uses the normal expanded Fold, Thread, or ReviewCard presentation. Buffer Search adds only the match and active-match styles. It adds no search-owned disclosure label.

At narrow widths, the command line preserves the `/`, the query end, and then the count when space permits. Match styles do not add glyphs or columns, so they cannot change wrapping.

The [Buffer Search Feedback prototype](../prototype-buffer-search-feedback.html) remains the visual source for normal, no-match, wrapped, SideBySide, hidden-match, and narrow-terminal cases.
