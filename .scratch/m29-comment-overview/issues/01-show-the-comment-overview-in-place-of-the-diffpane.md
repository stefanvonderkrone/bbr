# 01: Show the Comment Overview in place of the DiffPane

Status: ready-for-agent
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## What to build

A reviewer presses `g o` in a review Session.
The Comment Overview replaces the DiffPane in the Main Pane, and the Sidebar stays.
It lists every Comment, Reply, and Draft in Review order, one Overview Entry per item.
A Reply sits one indent step under its parent.
A root entry shows its scope, and every entry shows its author and an excerpt.
`g d` shows the DiffPane again at the exact cursor and scroll that it had.
`g o` shows the Comment Overview again with the same selection and scroll.
A Session replacement shows the DiffPane and resets the Comment Overview.

This slice has no Enter jump, no filters, no newest-first order, and no File Tree Filter.
Tickets 02, 03, and 04 add them.
The filter row shows only the query placeholder and the `o review order` chip in this slice.

## Scope

- Add `src/tui/comment_overview.zig` with `State`, `Order`, `Record`, `Index`, `buildIndex`, `Entry`, `Listing`, and `buildListing`.
  `buildListing` supports Review order and no filter in this slice.
  Add the module to the test import chain in `src/main.zig`.
- Export the Weave parent resolution and the posted-Draft alias from `src/tui/buffer.zig` for `buildIndex`.
- Add the excerpt helper to `src/tui/review_body.zig`.
- Add `MainPane`, `Published.main_pane`, `Published.overview`, `Published.overview_index`, `Published.overview_listing`, and `Published.overview_index_stale` to `src/tui/presentation.zig`.
- Add the Actions `show_comment_overview` and `show_diff_pane` with `g o` and `g d`.
  Add the Interaction Context `comment_overview` and its `supportsContext` arm.
  This slice supports the Motions and both new Actions in that context.
  It also supports the existing Actions of the spec list, except `open_file_finder` and `open_review_search`.
- Rebuild the index after each Draft, Draft state, or ScopeProjection change while the Comment Overview shows.
  Mark it stale while the DiffPane shows.
- Keep the selection by Owner across rebuilds, as the spec describes.
- Add `layouts.commentOverviewPanes`, the shared Sidebar View, `frame.overviewRects`, and `Projection.main_pane`.
- Add `render.drawCommentOverview` and the Main Pane paint switch in `src/tui/app.zig`.
- Add `OverviewPart`, `Theme.overviewStyle`, and the `comptime` check in `src/tui/theme.zig`.
- Add `HitTarget.overview_entry`.
  A click selects an entry, and the wheel scrolls the listing.
- Add the Comment Overview status hints and the listing position.
  Add the `g o` hint to the DiffPane status.
- Add the `StatusSlot` arms `filter`, `open`, and `main_pane`.
  The `filter` and `open` hints appear in tickets 03 and 02.
- Add the Command Palette entries "Show Comment Overview" and "Show DiffPane".
  Add `.comment_overview` to `pane_contexts`.
  Change the "Switch Pane" description.
- Add the help texts "show Comment Overview" and "show DiffPane".
- Add the `test-comment-overview` build target with the filter `M29 overview`.

## Acceptance criteria

- [ ] The index lists Review-level, File-level, new-side inline, old-side inline, and range Comments with their scope labels.
- [ ] The index lists Replies at their depth, Draft roots, Draft Replies to Comments, and Draft Replies to Drafts.
- [ ] The index lists resolved Threads, Deleted Comments, and outdated, moved, and unavailable items with their states.
- [ ] The index hides a `submitting` Draft and lists a `posted` Draft until its Comment is fetched.
- [ ] "M29 overview the index lists the DiffPane ReviewCards with every disclosure open" passes.
- [ ] Review order puts Review-level Threads first, then Files in File Tree order, then Lines.
- [ ] The excerpt applies mention names, collapses whitespace, and stops at 200 bytes on a scalar boundary.
- [ ] `g o` shows the Comment Overview from the DiffPane and from the Sidebar, and focus goes to the Main Pane.
- [ ] `g o` while the Comment Overview shows changes nothing, and `g d` while the DiffPane shows changes nothing.
- [ ] `g d` restores the DiffPane cursor, scroll, and Selection from before `g o`.
- [ ] `g o` after `g d` restores the Comment Overview selection and scroll.
- [ ] "M29 overview showing the Comment Overview changes no disclosure" passes.
- [ ] Tab moves focus between the Sidebar and the Comment Overview.
- [ ] The Motions and a Count move the selection, and the scroll follows it.
- [ ] A Review-level Draft saved with `C` from the Comment Overview appears, and the selection keeps its Owner.
- [ ] An allocation failure in the index or listing build keeps the previous Frame.
- [ ] "M29 overview a Session replacement shows the DiffPane and resets the Overview State" passes.
- [ ] A failed Session replacement keeps the Comment Overview and its Overview State.
- [ ] "M29 overview the Comment Overview Panes match the DiffPane Panes at every size" passes.
- [ ] "every layout places each of its Slots" covers `layouts.commentOverviewPanes`.
- [ ] The Comment Overview has rounded corners, the Title `Comment Overview <matches>/<records>`, and a rule that joins the border.
- [ ] "M29 overview the Main Pane paints one Pane at a time" passes.
- [ ] "M29 overview paints the Theme base background" passes for every built-in Theme.
- [ ] A narrow entry row cuts the path start and the row end with `…`.
- [ ] An empty Review shows "No Comments or Drafts in this Review".
- [ ] A click selects an entry, and the wheel scrolls the listing.
- [ ] The status shows the Comment Overview hints and the listing position.
- [ ] `g o` and `g d` pass `validateBindings`, and a `[keymap]` override can rebind and unbind both.
- [ ] The Command Palette lists "Show Comment Overview" and "Show DiffPane" from the DiffPane, the Sidebar, and the Comment Overview.

## Tests that prove it

- Index and listing fixtures in `src/tui/comment_overview.zig`.
- Presentation tests in `src/tui/presentation.zig`.
- Layout tests in `src/tui/layouts.zig`.
- Render tests in `src/tui/render.zig` and status tests in `src/tui/app.zig`.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`
