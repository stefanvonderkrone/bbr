# Choose the Sidebar File Tree interaction

Type: prototype
Status: resolved
Blocked by: none

## Question

What File Tree structure and keyboard behavior make repository paths easy to scan and navigate while preserving the fixed requirements for active-File visibility, centered Sidebar scrolling, collapsible Directories, right-aligned counts, ellipsis truncation, and sensible behavior at narrow terminal widths?

## Answer

Adopt the prototype's **B — Compacted outline** contract.

- Build a repository-path tree from the Diff's Files. Render Files by leaf name and render every maximal, non-branching Directory chain as one slash-terminated Directory entry such as `docs/adr/`; keep separate Directory entries wherever paths branch. Directory expansion is keyed by its full canonical path, is Session-relative, survives Buffer rebuilds, and resets with Session replacement.
- Make the Sidebar a focusable Pane with a tree cursor distinct from the active File. `Tab` moves focus between Sidebar and DiffPane. On entry, put the tree cursor on the active File when visible, otherwise on its nearest visible collapsed ancestor.
- In the focused Sidebar, `j`/`k` and down/up move across visible Directory and File entries. `h`/left collapses an open Directory or moves to its parent; `l`/right expands a closed Directory or moves to its first child. `Enter` toggles a Directory or focuses a File by moving the DiffPane cursor to that File's header; focusing a File keeps Sidebar focus so several Files can be inspected before returning to the DiffPane. Counts do not apply to tree motions.
- Retain `[`/`]` as previous/next File Actions while the DiffPane is focused. Whenever navigation changes the active File, expand its ancestors and scroll its File entry near the Sidebar's vertical center, clamping naturally at the first and last entries. Explicitly collapsing an ancestor of the current active File is allowed; that Directory shows an active-descendant marker, and the next active-File change reopens the required path.
- Give each File row three independently laid-out regions: left-side active/disclosure/change-status cells, a flexible leaf-name cell, and a fixed right-side comment/draft tally. Omit zero tallies, but reserve the exact width required by non-zero tallies before laying out the name. Truncate the name with a terminal-width-aware ellipsis; indentation yields before the tally when the terminal is exceptionally narrow. Directory rows have disclosure plus their compact path and no synthesized aggregate comment count.
- Keep Directory expansion and the tree cursor in Presentation-owned Session state; keep the active File derived from the DiffPane cursor as it is today. The File Tree is a projection of those two inputs, not new Review or Diff domain state.

Prototype context: branch `prototype/m15-sidebar-file-tree`, commit `99793ff`, path `.scratch/m15-presentation-navigation-polish/prototypes/sidebar-file-tree/`.

## Comments

- 2026-08-04: Interactive Sidebar File Tree prototype prepared with Explicit outline, Compacted outline, and Directory groups variants. It exercises centered active-File scrolling and fixed right-edge tallies from 18–38 columns. Captured on branch `prototype/m15-sidebar-file-tree` at commit `99793ff`.
- 2026-08-04: Human selected B — Compacted outline.
