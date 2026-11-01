# 01: Show the Comment Overview in place of the DiffPane

Status: resolved
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

- [x] The index lists Review-level, File-level, new-side inline, old-side inline, and range Comments with their scope labels.
- [x] The index lists Replies at their depth, Draft roots, Draft Replies to Comments, and Draft Replies to Drafts.
- [x] The index lists resolved Threads, Deleted Comments, and outdated, moved, and unavailable items with their states.
- [x] The index hides a `submitting` Draft and lists a `posted` Draft until its Comment is fetched.
- [x] "M29 overview the index lists the DiffPane ReviewCards with every disclosure open" passes.
- [x] Review order puts Review-level Threads first, then Files in File Tree order, then Lines.
- [x] The excerpt applies mention names, collapses whitespace, and stops at 200 bytes on a scalar boundary.
- [x] `g o` shows the Comment Overview from the DiffPane and from the Sidebar, and focus goes to the Main Pane.
- [x] `g o` while the Comment Overview shows changes nothing, and `g d` while the DiffPane shows changes nothing.
- [x] `g d` restores the DiffPane cursor, scroll, and Selection from before `g o`.
- [x] `g o` after `g d` restores the Comment Overview selection and scroll.
- [x] "M29 overview showing the Comment Overview changes no disclosure" passes.
- [x] Tab moves focus between the Sidebar and the Comment Overview.
- [x] The Motions and a Count move the selection, and the scroll follows it.
- [x] A Review-level Draft saved with `C` from the Comment Overview appears, and the selection keeps its Owner.
- [x] An allocation failure in the index or listing build keeps the previous Frame.
- [x] "M29 overview a Session replacement shows the DiffPane and resets the Overview State" passes.
- [x] A failed Session replacement keeps the Comment Overview and its Overview State.
- [x] "M29 overview the Comment Overview Panes match the DiffPane Panes at every size" passes.
- [x] "every layout places each of its Slots" covers `layouts.commentOverviewPanes`.
- [x] The Comment Overview has rounded corners, the Title `Comment Overview <matches>/<records>`, and a rule that joins the border.
- [x] "M29 overview the Main Pane paints one Pane at a time" passes.
- [x] "M29 overview paints the Theme base background" passes for every built-in Theme.
- [x] A narrow entry row cuts the path start and the row end with `…`.
- [x] An empty Review shows "No Comments or Drafts in this Review".
- [x] A click selects an entry, and the wheel scrolls the listing.
- [x] The status shows the Comment Overview hints and the listing position.
- [x] `g o` and `g d` pass `validateBindings`, and a `[keymap]` override can rebind and unbind both.
- [x] The Command Palette lists "Show Comment Overview" and "Show DiffPane" from the DiffPane, the Sidebar, and the Comment Overview.

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

## Comments

- The index derives from the DiffPane Buffer. `buffer.reviewCardNodes` runs `buildWithComments` with every disclosure open and returns one node per ReviewCard with its Weave parent. So the two views cannot disagree on membership, parents, or posted-Draft aliases.
- The index build uses the fetched Diff in unified layout: no folds, no WholeFile blobs, no isolation. So the index depends only on the Session, the Drafts, and the ScopeProjection, which are the rebuild triggers of the SPEC. A Thread on a Line that only WholeFile shows is not listed. The DiffPane does not show it in the Changes or Fetched scope either.
- Every Draft change path marks `Published.overview_index_stale`. `Presentation.dispatch` rebuilds a stale index at its end while the Comment Overview shows. A failure keeps the previous index and listing, keeps the stale mark, and reports `out_of_memory`.
- A first show selects the first entry. A selection that leaves the viewport moves the scroll the minimum distance.
- The excerpt uses prose first, then "suggestion", then the first non-blank code or literal line, then an empty text.
- `Record.recency_rank` is not in this slice. Ticket 03 adds it with newest first.
- The status puts the `main_pane` hint before the submit hint, after the `filter` and `open` slots. So the Comment Overview hints follow the SPEC order.
- The test "unbinding a default can free its Leader for a shorter Action" in `src/tui/config.zig` now also unbinds `show_comment_overview` and `show_diff_pane`, because `g o` and `g d` keep `g` as a Leader.
- Left for ticket 04: Enter on a File Tree File while the Comment Overview shows still runs the File Jump in the hidden DiffPane, and focus goes to the Comment Overview.
- The second review fix round touched this ticket: M29-6 (root entry Actions), M29-8 (resize scroll), M29-10 (`g o` focus), M29-11 (excerpt cut), and the `showMainPane` owner. Ticket 06 records the fixes.

## Completion

Commit: see the `tui: show the Comment Overview in the Main Pane` commit. Changed paths: `build.zig`, `src/main.zig`, `src/tui/comment_overview.zig` (new), `src/tui/buffer.zig`, `src/tui/review_body.zig`, `src/tui/file_tree.zig`, `src/tui/layouts.zig`, `src/tui/frame.zig`, `src/tui/theme.zig`, `src/tui/render.zig`, `src/tui/presentation.zig`, `src/tui/action.zig`, `src/tui/keymap.zig`, `src/tui/list_overlay.zig`, `src/tui/app.zig`, `src/tui/config.zig`.

Summary: `g o` shows the Comment Overview in the Main Pane, and `g d` shows the DiffPane again. The Overview Index and Overview Listing live in their own `ArenaRing(2)` in `Published` and publish in one infallible step. The Comment Overview is the View tree `layouts.commentOverviewPanes`, painted by `render.drawCommentOverview`, with `Theme.overviewStyle` and its `comptime` base-background check.

Checks:

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-comment-overview`: 35/35 pass.
- `zig build test --summary all`: 1409/1409 pass (baseline 1378).
- `python3 tools/check_agent_docs.py`: pass.

Review result: the runner read the `buffer.zig` and `presentation.zig` diffs and reran every check. The runner found no blocking issue.
