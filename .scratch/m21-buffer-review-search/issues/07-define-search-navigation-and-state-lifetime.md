Type: grilling
Status: resolved
Blocked by: 02, 05, 06

# Define Search Navigation and State Lifetime

## Question

How should either search move to an exact source or authored occurrence and retain or clear search state as Presentation changes?

Define File focus, version focus, WholeFile activation for out-of-Hunk source, exact source or ReviewBody cursor placement, horizontal visibility, disclosure expansion, and Overlay closure. Define how Layout, Scope, wrapping, isolation, refresh, Session replacement, and Review switching affect queries, active matches, selection, and return to Review Search. Resolve whether selecting a version-specific Review Search result changes Selected Version or only the immediate destination.

## Answer

### Active search and lifetime

Buffer Search and Review Search keep separate state while the Session remains current. Presentation shows highlights for only one active search.

- `open_buffer_search` makes Buffer Search active and hides Review Search highlights.
- `open_review_search` makes Review Search active and hides Buffer Search highlights.
- Switching the active search does not clear the other search's query, occurrences, active occurrence, or selection.
- Closing Review Search keeps it active. Its visible results remain highlighted in the DiffPane until Buffer Search becomes active or the Session changes.
- DiffPane Motions, pointer navigation, Layout changes, Scope changes, and isolation changes do not clear Review Search highlights or selection.

Review Search retains its query, available results, and selected Search Occurrence when its Overlay closes. Reopening the Overlay restores them. If a body mutation removes the selected occurrence, Review Search rescans and selects the next ranked occurrence at the old list position. It clamps to the final result when no result remains at that position. An empty result set has no selection.

Every Session replacement clears both searches, including their queries, occurrences, highlights, counts, and selections. This rule applies to explicit refresh and Review switching, even when a refresh loads the same ReviewIdentity. Selected Version keeps its existing process lifetime and does not reset with search state.

Buffer Search retains the in-Session rebuild behavior from [Define Buffer Search Interaction](02-define-buffer-search-interaction.md). A Review Search query never becomes a Buffer Search query, and a Buffer Search query never becomes a Review Search query.

### Source navigation

Opening a source occurrence closes Review Search only after Presentation can publish a Frame that contains the exact destination.

- Focus the occurrence's File. If the DiffPane already isolates a File, replace that isolated File. If it shows all Files, keep the all-Files projection.
- Preserve Layout.
- For an old or new occurrence, set Selected Version to that version. A version-neutral occurrence keeps the current Selected Version.
- Keep the current Scope when the source Line belongs to a visible Hunk. Expand a containing Fold through a search-owned reveal without changing the saved Fold state.
- Switch to WholeFile when the source Line is outside a Hunk. This Scope change remains after navigation.
- Put the DiffPane row cursor on the first wrapped visual row that contains the occurrence's first matched range. Highlight every matched range that projects into the current Buffer. The result highlight is independent of the row cursor highlight.

The search-owned Fold reveal lasts while that occurrence remains the Review Search selection and Review Search remains active. Selecting another occurrence, activating Buffer Search, or replacing the Session restores the saved Fold state.

M21 makes DiffPane source wrapping unconditional. It removes the `toggle_diff_wrap` Action and the Presentation wrapping preference. bbr has no horizontal source scrolling, so an unwrapped Line can hide the exact destination. Wrapped visual rows keep every source range reachable through the existing vertical scrolling model.

Review Search keeps all available result ranges highlighted when those occurrences project into the current Buffer. Cursor movement does not clear these highlights. A Buffer reprojection recomputes their visual placement from Search Occurrence identity.

### ReviewBody navigation

Opening an authored occurrence focuses its owning ReviewCard and its exact logical body line.

- A Review-level item exits File isolation and navigates to its ReviewCard in the all-Files Buffer.
- A File-level item focuses its File. If isolation is active, it replaces the isolated File.
- An inline item focuses its File and ReviewCard. For a current or moved Anchor, navigation also selects the Anchor's old or new version. An outdated or unavailable item keeps the current Selected Version because it has no current source Line.
- A Reply or Draft follows the same rule as its root CommentScope.
- Navigation opens every Thread, ReviewCard, Outdated section, or other disclosure needed to show the owner. These changes update the saved disclosure state and remain after navigation.
- The row cursor lands on the first projected ReviewBody row that contains the occurrence's first range. Every matched range remains highlighted independently of cursor movement.

M21 uses the existing DiffPane ReviewCards for these destinations. A separate Comment Overview is outside M21 and is planned as M29 in `TODO.md`.

### Acquisition and failed navigation

If File content was evicted after Review Search produced a source occurrence, opening that occurrence reacquires the required File Enrichment. The Overlay stays open and shows loading state during acquisition. Successful acquisition publishes the destination Frame and then closes the Overlay.

An acquisition failure keeps the Overlay open, retains the query and selection, and exposes the File version failure. Review Search does not navigate to a placeholder or an approximate Line. Session Epoch and query-generation checks from [Define Streaming File Acquisition](06-define-streaming-file-acquisition.md) still reject stale work.

Escape closes the Overlay without navigation. The current Review Search query, results, selection, and DiffPane highlights remain available for the current Session.
