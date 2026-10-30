# M29 Comment Overview: brief

Status: ready-for-agent
Milestone: M29

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M29.
The requirements live in the M29 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Review glossary](../../src/review/GLOSSARY.md) and [the Presentation glossary](../../src/tui/GLOSSARY.md).

## In my own words

Today, a reviewer finds Comments, Replies, and Drafts only by scrolling the DiffPane or by Review Search.
A Review with many Threads across many Files has no single list of its discussion.
The reviewer cannot see quickly which Threads are still open, which Drafts are waiting, or which items are their own.

The goal is one list of every authored item in the Review.
The reviewer can filter it to "what still needs my action" and jump from an item to its ReviewCard.
The list stays where it was when the reviewer comes back, so it works as a work queue.

## Expert approach

- Prior art: the "Conversations" panel of GitHub and the Bitbucket Cloud Comment list.
  Both list Threads in File order, filter unresolved Threads, and jump to the code.
- Method: the Comment Overview is a projection of the Session's existing Comments and Drafts.
  It adds no new data source and no new persistence.
  It takes the DiffPane's place in the existing View tree (ADR-0013), so the layout does not change.
  It is one more state in the Presentation state machine (ADR-0012).
- Outside check: on a real PullRequest with many Threads, count the items in the Overview and compare the count with the Bitbucket web UI.
  Then switch between the Overview and the DiffPane several times, and confirm that each view keeps its cursor, scroll, query, and filters.

## Decisions

The user made these decisions on 2026-10-30.

1. **The Comment Overview replaces the DiffPane in the main area.**
   The main area shows either the DiffPane or the Comment Overview.
   The File Tree Sidebar stays.
   There is no right Sidebar and no responsive layout.
   The user reverted an earlier right-Sidebar design on the same day.
2. **Default keys: `g o` shows the Comment Overview, and `g d` shows the DiffPane.**
   `g o` binds `show_comment_overview`, and `g d` binds `show_diff_pane`.
   Each key shows its view directly and does nothing when that view already shows.
   Both Actions are configurable.
   `g d` was free in the default Keymap on 2026-10-30.
   M22 takes `m`, and M24 takes `b`.
3. **One row per authored item, nested.**
   Every Comment, Reply, and Draft is a row.
   A Reply indents under its parent, as in the DiffPane.
4. **Switchable order.**
   The default is Review order: Review-level items first, then Files in File Tree order, then Lines.
   An Action switches to newest first and back.
5. **Filters: a fuzzy query, unresolved only, Drafts only, and mine only.**
   The query matches author, body, and path.
   "Mine" means items by the Authenticated Account.
   For a LocalReview, every Draft counts as mine.
6. **The File Tree filters the Overview.**
   While the Overview shows, selecting a File or a directory in the File Tree narrows the Overview to its items.
   Selecting the root clears this filter.
7. **`Enter` on an item switches to the DiffPane at the item's ReviewCard.**
   `g o` shows the Overview again, and the Overview keeps its query, filters, order, selection, and scroll position for the Session.
8. **No source context in the Overview for now.**
   A row shows the scope (Review, File path, or path and Line), the author, and a one-line body excerpt.
9. **The DiffPane always shows at start.**
   There is no config key for the start view.

## Specification changes

- Changed: "Define the Comment Overview projection" now means a view that replaces the DiffPane in the main area, not an Overlay or a new Pane.
- Added: the File Tree filter (decision 6).
- Deferred: "Show nearby source Lines for an inline item".
  File and ReviewHeader context are also deferred.
- Changed: the Review Search route for a Review-level item switches to the Overview and selects the item.
- Decide in `SPEC.md`: whether the Overview is a new Pane name or a mode of the main Pane, and the matching glossary terms.
  The AGENTS.md rules for Pane Titles and touching Panes apply to the Overview unchanged.
- Kept: listing resolved, outdated, unavailable, and collapsed items without changing their disclosure state.
  Kept: Presentation coverage for each CommentScope, nested Replies, Drafts, disclosures, stale Session work, navigation, and return-state restoration.
  Added coverage: the File Tree filter and the view switch.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the implementation tickets in this directory.
