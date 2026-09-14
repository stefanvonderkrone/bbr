Type: prototype
Status: resolved
Blocked by: 04

# Prototype Review Search Overlay

## Question

What Review Search Overlay lets the reviewer query, compare, preview, and select streamed occurrences without losing context?

Build a cheap two-column Overlay prototype with result positions on the left and the selected result preview on the right. Prototype source result rows with path, version, line, column, and snippets. Prototype authored result rows with owner and Review, File, or inline context. Highlight every query hit in the preview. Cover loading, partial failure, binary and unavailable versions, no matches, reordered streamed results, long paths, long Lines, long ReviewBodies, and narrow terminals. Define keyboard and mouse parity through Actions, including `g f`, arrows, `ctrl-n`, and `ctrl-p`.

## Comments

- Interactive prototype: [Review Search Overlay](../prototype-review-search-overlay.html).

## Answer

The human selected variant B, the dense result table, without matched Line text in the result list. The Preview owns all matched content.

### Overlay structure

Review Search uses a large responsive Overlay over the current Presentation Frame. The header contains the `Review Search` title, a `>` query prompt, the query, and available-result and candidate counts.

In a landscape terminal, the result list and Preview appear horizontally side by side. The result list is wider than the Preview at normal terminal widths. In a portrait terminal, the result list appears above the Preview. Each region scrolls independently in both arrangements.

The result list contains three fields:

- `Kind`: `OLD`, `NEW`, `OLD+NEW`, `COMMENT`, `REPLY`, or `DRAFT`;
- `Source`: the File path for source occurrences, or the author and CommentId or TempId for ReviewBody occurrences;
- `Position`: `L<line>:C<column>` for source, or `body L<line>:C<column>` for ReviewBody text.

The list does not repeat matched Line text. This keeps each occurrence to one dense row and leaves matched content in one place.

The right column shows the selected Search Occurrence. Source previews show the complete path, version relation, position, and nearby source Lines. ReviewBody previews show the owner, CommentScope context, logical body line, and enough surrounding authored text to identify the occurrence. The selected logical line has the existing cursor accent. Every scalar used by the fuzzy match has the Theme's search highlight.

### Streamed and exceptional states

Each publication globally reorders available Search Occurrences by the ordering from [Define Review Search Matching and Ordering](04-define-review-search-matching-and-ordering.md). It retains the selected Search Occurrence by identity and keeps the Preview fixed on that occurrence when its list row moves.

The left column includes non-selectable status rows after available occurrences. Each row names the File version and one state: loading, absent, binary with a known size when available, invalid UTF-8, or acquisition failure. A partial failure does not remove usable occurrences or their Preview.

A query with no available match shows `No matching occurrence` in the list and `No preview` in the Preview. Acquisition states remain visible. New matching results replace the empty state when they arrive.

At narrow widths, the header hides the title before it removes the query. Long paths truncate in the list and remain complete in the Preview. Source Lines scroll horizontally inside the Preview. ReviewBody text wraps there.

### Actions and pointer parity

Review Search adds these configurable Actions:

- `open_review_search`, bound to `g f` by default;
- `next_review_search_occurrence`, bound to Down and `ctrl-n` by default;
- `previous_review_search_occurrence`, bound to Up and `ctrl-p` by default;
- `open_search_occurrence`, bound to Enter by default.

The Overlay captures input. Down, Up, `ctrl-n`, and `ctrl-p` change the selected Search Occurrence with wraparound and scroll its row into view. Enter opens the selected occurrence. Escape closes the Overlay without navigation.

A primary mouse click on a result dispatches selection of that Search Occurrence. A primary double-click dispatches `open_search_occurrence`. Keyboard and pointer input use the same selection and opening paths. The existing mouse wheel scrolls the list or Preview under the pointer.
