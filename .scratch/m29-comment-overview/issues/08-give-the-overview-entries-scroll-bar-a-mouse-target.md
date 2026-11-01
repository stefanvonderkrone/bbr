# 08: Give the Overview entries scroll bar a mouse target

Status: needs-triage
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## Problem

This defect exists only after both M29 and M30 merge into one tree.
M30 adds `frame.ScrollBar` with the arms `sidebar`, `diff_pane`, and `review_search_list`.
M30 has no arm for the Comment Overview entries scroll bar.

The merge plan records two defects in the tree with both branches:

- While the Comment Overview shows, a press or a drag on the Main Pane right border scrolls the hidden DiffPane.
  A probe test measured the hidden DiffPane scroll change from 0 to 40.
- The Comment Overview entries scroll bar ignores the mouse.
  It has no press target, no jump, and no Scroll Drag.

Source: decision D2 in `merge-plan-all-branches.md`, section 7.
The step 6 section of `merge-recipes/sequence-D.md` (H2) lists the parts of the fix.
The cross-branch row "m29 x m30" in the merge plan also names this defect.

The operator chose a follow-up ticket instead of a fix in the M29 merge commit.
The M29 branch alone has no `frame.ScrollBar`, so the M29 branch does not show the defect.

## What to build

Do this work in the tree that holds both M29 and M30.

1. Add the arm `comment_overview_entries` to `frame.ScrollBar`.
2. In `frame.scrollState`, return null for `comment_overview_entries` unless the Comment Overview shows.
   The track is the entries track from `frame.overviewRects`.
   The total is the count of Overview Entries, and the offset is the Overview scroll.
3. In `frame.scrollState`, return no thumb for `diff_pane` unless the DiffPane shows.
4. In `frame.scrollTarget`, apply the same Overlay rule as for `diff_pane`.
5. In `frame.hitTest`, make the `diff_pane` hit unreachable while the Comment Overview shows.
6. In `Presentation.scrollBarTo` and the Scroll Drag path, add an arm that sets the Overview scroll.
   That arm changes neither the selected entry nor the DiffPane navigation.
7. Make `drawCommentOverview` take its entries scroll from `frame.scrollState`.
   Then paint and hit testing use the same numbers.
8. Add the new test names to the M30 AGENTS.md row "A new scroll bar is one arm of `frame.ScrollBar`".

## Acceptance criteria

- [ ] A press on the Main Pane right border while the Comment Overview shows does not scroll the DiffPane.
- [ ] A press and a drag on the entries track scroll the listing and keep the selected entry.
- [ ] A switch to the DiffPane during a drag ends the drag.
- [ ] The test "every scroll bar hit target matches the painted thumb" covers the Comment Overview.
- [ ] No DiffPane Scroll Mark shows while the Comment Overview shows.
- [ ] `zig build test` and `python3 tools/check_agent_docs.py` pass.
