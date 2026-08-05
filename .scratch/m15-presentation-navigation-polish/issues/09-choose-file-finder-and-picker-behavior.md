# Choose File finder and PullRequest Picker behavior

Type: prototype
Status: resolved
Blocked by: 02, 08

## Question

How should File fuzzy finding and PullRequest picking share an understandable Overlay interaction while the File finder focuses a selected File, PullRequest title outranks id without disabling id matches, the Picker's initial adjacent-branch filter is visible and easy to clear if retained, and both honor the mouse navigation contract established by [Decide M15 mouse support](08-decide-m15-mouse-support.md)?

## Answer

Adopt the prototype's **B — Purpose-shaped overlays** contract. The File finder and PullRequest Picker are separate Overlays with separate Actions and consequences; they share an input grammar, not a mode switch.

- Keep `p` as `open_picker` for the PullRequest Picker and add `F` as `open_file_finder`. Their help text is `open PR picker` and `find changed file`. Neither Overlay can switch into the other, and each title states its effect: `Find File` versus `Open Pull Request`.
- Give both Overlays the same transient interaction: the query is focused on open; typing filters; up/down and `ctrl-p`/`ctrl-n` move the selection; wheel input scrolls under the pointer; a click only moves selection; `Enter` is the sole confirmation; and Escape or `ctrl-c` dismisses without changing the review. Empty and no-match states remain explicit, and opening either Overlay starts with a fresh query and first-row selection.
- The File finder searches only Files changed by the current Session's Diff. Match against both canonical repository path and leaf name; show the leaf as primary text and the path as secondary text, with change status and non-zero comment/draft tallies available at the row edges. An empty query preserves Diff order. Confirming closes the Overlay, expands the chosen File's Sidebar ancestors, focuses that File through the established Sidebar/DiffPane active-File transition, and reveals it near the Sidebar center without replacing the Session.
- The PullRequest Picker opens on **all open PullRequests immediately**. Remove the adjacent-branch initial filter and its hidden filtered state; source branch remains visible and searchable metadata. An empty query preserves the API's list order.
- Rank PullRequest title matches ahead of id, branch, and author matches. A bare numeric query still follows title-first ranking, so `15` may rank a title containing `M15` above PullRequest `#15`; an explicit `#15` query is the direct-id route. Id matching therefore remains fast without allowing incidental id text to dominate title relevance.
- Confirming a PullRequest closes the Overlay and begins the existing Candidate Session replacement; confirming a File never leaves the current Session. A loading PullRequest Picker accepts query input and applies it when results arrive, while the File finder is populated synchronously from the published Diff.
- Reuse the mouse contract from [Decide M15 mouse support](08-decide-m15-mouse-support.md): clicking a result selects but never confirms, wheel input does not change Pane focus, stale or clipped geometry cannot activate a row, and all mouse behavior has the keyboard path above.

The deterministic acceptance matrix must cover separate Action availability and help entries, query reset and dismissal, empty/no-match/loading states, File path/leaf matching and focus effects, all-open PullRequest startup, title-first versus bare/explicit id ranking, keyboard navigation, mouse selection/scrolling, Enter-only confirmation, and the distinct Session effects of each Overlay.

Prototype context: branch `prototype/m15-file-pr-picker`, commit `29d37e7d48592812ed42b41d991181b6b8dd4b68`, path `.scratch/m15-presentation-navigation-polish/prototypes/file-pr-picker/`.

## Comments

- 2026-08-05: Interactive prototype prepared with A — Shared modes, B — Purpose-shaped overlays, and C — Scoped command picker; preserved on branch `prototype/m15-file-pr-picker` at commit `29d37e7`.
- 2026-08-05: Human selected separate purpose-shaped Overlays and chose to show all open PullRequests immediately, with no adjacent-branch initial filter.
