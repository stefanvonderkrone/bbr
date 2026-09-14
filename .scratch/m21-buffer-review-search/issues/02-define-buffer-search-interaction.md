Type: grilling
Status: resolved
Blocked by: 01

# Define Buffer Search Interaction

## Question

How should Buffer Search behave from `/` through query input, acceptance, cancellation, and `n` or `N` traversal?

Define literal smart-case matching, incremental updates, the active and total match count, wraparound, no-match feedback, empty-query reuse, and cursor restoration. Define how an active match reveals hidden source or authored text. Cover Layout, Scope, wrapping, isolation, Buffer rebuilds, mouse input, Count, Selection, and configurable Actions.

## Answer

### Actions and input

Buffer Search adds three configurable Actions:

- `open_buffer_search`, bound to `/` by default;
- `next_search_occurrence`, bound to `n` by default;
- `previous_search_occurrence`, bound to `N` by default.

The Actions apply only to DiffPane Interaction Contexts. `open_buffer_search` is unavailable while Selection is active. The refusal tells the reviewer to clear Selection first. Buffer Search does not save, hide, or change a Selection.

`open_buffer_search` starts inline query input rather than an Overlay. Query input captures keyboard input and ignores mouse input. It accepts Unicode scalar input at the end of the query. Backspace removes one Unicode scalar. `ctrl-w` removes the previous whitespace-delimited word and adjacent trailing whitespace. `ctrl-u` clears the query. The query has no movable input caret. Line endings and invalid UTF-8 cannot enter the query.

Count follows Neovim and less. A Count before `/` selects that numbered occurrence. A Count before `n` or `N` moves by that many occurrences. Cancellation, confirmation, and traversal consume the Count.

### Query lifecycle

`/` opens with an empty input line. The prior accepted query, highlights, active occurrence, and active and total match count remain visible until the reviewer enters query text. If query editing returns the input to zero bytes, the prior accepted search appears again. Whitespace is literal searchable text. Only zero bytes make a query empty.

Each nonempty edit applies the literal smart-case rules from [Define Search Corpus and Occurrence Identity](01-define-search-corpus-and-occurrence-identity.md). Buffer Search updates all occurrences, the active occurrence, match highlights, and the active and total count after each edit. It moves the highlighted DiffPane row to the active occurrence as part of this preview.

The first occurrence on the highlighted visual row is the search origin. If that row has no occurrence, Buffer Search takes the next semantic occurrence and wraps when necessary. Count advances from this origin. When an edit keeps a match at the active semantic location, that match remains active. Otherwise Buffer Search selects from the saved search origin.

`Esc` cancels query input. Cancellation restores the highlighted row, scroll position, accepted query, active occurrence, and highlights that existed before `/`. `Enter` confirms the previewed query and keeps its highlighted row. Query input then closes. The reviewer uses `n` and `N` without another `Esc`.

An empty `Enter` reuses the prior accepted query and moves forward by Count occurrences, with wraparound. Without a prior accepted query, an empty `Enter` closes query input without movement.

A nonempty query with no matches can be confirmed. It keeps the saved location, shows `0/0`, and becomes the accepted query. `n` and `N` then report that the query has no matches without movement.

### Occurrence order and traversal

Traversal uses semantic Buffer order rather than visual-row duplication. Hidden content keeps the position of its owning Fold or ReviewCard. Authored occurrences follow their owner and logical body-line order. SideBySide source occurrences on the same projected line order old before new. A Diff-proven version-neutral occurrence appears once.

Occurrences on one semantic Line order by their first matched byte range from left to right. Each occurrence contributes one item to the total. `n` moves forward and `N` moves backward. Both Actions traverse exact occurrences on the same Line before leaving that Line.

Traversal wraps. Forward wrap reports `search hit BOTTOM, continuing at TOP`. Backward wrap reports `search hit TOP, continuing at BOTTOM`. The active and total count remains visible with the message.

A Motion or accepted mouse click that moves the highlighted DiffPane row clears the active occurrence but retains the accepted query and all match highlights. The count then shows `-/total`. From this state, `n` starts after the complete highlighted row and `N` starts before it. The selected occurrence establishes a new active count.

### Projection and disclosure behavior

An active occurrence forces open only the Fold, Thread, ReviewCard, or containing disclosure chain needed to show it. This reveal is search-owned and does not change the reviewer's saved disclosure state. Leaving the occurrence restores each prior disclosure state. If that restoration removes the highlighted row, the owning persistent disclosure row becomes the highlighted row.

One occurrence can cross a visual wrapping boundary. Every covered visual continuation shows its part of the match highlight. The first covered continuation becomes the highlighted row, and the occurrence contributes one item to the count.

Match navigation follows Neovim's default viewport behavior. If the active visual row is already visible, scrolling does not change. Otherwise Presentation scrolls only enough to reveal the row at the nearest viewport edge.

Layout, Scope, wrapping, isolation, disclosure, and authored-body changes rebuild the Buffer Search projection from the accepted query. Buffer Search retains the active Search Occurrence identity when that occurrence remains in the corpus. Otherwise it selects the next occurrence at or after the prior semantic location, with wraparound. If no occurrence remains, it keeps the nearest valid highlighted row and shows `0/0`.

[Prototype Buffer Search Feedback](03-prototype-buffer-search-feedback.md) owns the exact prompt, highlight, active-highlight, count, no-match, and narrow-terminal presentation. [Define Search Navigation and State Lifetime](07-define-search-navigation-and-state-lifetime.md) owns behavior across Session replacement and Review switching.
