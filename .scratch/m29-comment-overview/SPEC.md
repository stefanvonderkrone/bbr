# M29 Comment Overview

Status: ready-for-agent
Milestone: M29

The [M29 brief](brief.md) records the approved decisions.
This spec turns the brief and the M29 section of [TODO.md](../../TODO.md) into buildable form.
The implementation tickets live in [issues](issues/).

## Problem Statement

Today, a reviewer finds Comments, Replies, and Drafts only in the DiffPane or through Review Search.
A Review with many Threads across many Files has no single list of its discussion.
The reviewer cannot see quickly which Threads are open, which Drafts wait, or which items are their own.
The reviewer also cannot use the discussion as a work queue, because no list keeps its place.

## Solution

The reviewer presses `g o`.
The Comment Overview replaces the DiffPane in the Main Pane.
The Sidebar and its File Tree stay.
The Comment Overview lists every Comment, Reply, and Draft as one Overview Entry.
A Reply sits under its parent with one more indent step.

The reviewer filters the list with a fuzzy query and three toggles: unresolved only, Drafts only, and mine only.
The File Tree narrows the list to one File or Directory while the Comment Overview shows.
The reviewer switches between Review order and newest first.

Enter on an Overview Entry shows the DiffPane with the cursor on the entry's ReviewCard.
`g o` shows the Comment Overview again with the same query, filters, order, selection, and scroll.
`g d` shows the DiffPane without a jump.
The DiffPane always shows at start and after a Session replacement.

A Review Search result for a Review-level Comment or Draft opens in the Comment Overview.
Other Review Search results keep the M21 route to the DiffPane.

The Comment Overview is a projection of the Session's Threads and the PendingReview's Drafts.
It adds no data source and no persistence.

## User Stories

Stories 1 to 30 are from the reviewer.
Stories 31 and 32 are from the maintainer.

1. I want `g o` to list every Comment, Reply, and Draft, so that I see the whole discussion.
2. I want `g d` to show the DiffPane again, so that I return to the code without a jump.
3. I want `g o` and `g d` to do nothing in their own view, so that a repeated key is harmless.
4. I want the File Tree beside the Comment Overview, so that I keep my place in the Files.
5. I want each Reply under its parent, so that the conversation structure stays clear.
6. I want each root entry to show its scope, so that I know where the Thread lives.
7. I want each entry to show its author and an excerpt, so that I can scan quickly.
8. I want resolved, outdated, unavailable, deleted, and collapsed items listed, so that nothing hides from me.
9. I want the listing to change no DiffPane disclosure, so that the DiffPane stays as I left it.
10. I want Review order by default, so that the list follows the File Tree.
11. I want newest first on one key, so that I see recent activity at the top.
12. I want a fuzzy query over author, body, and path, so that I find one discussion fast.
13. I want an unresolved-only toggle, so that I see what still needs action.
14. I want a Drafts-only toggle, so that I check my pending work before Submission.
15. I want a mine-only toggle, so that I follow up on my own Comments and Drafts.
16. I want every Draft to count as mine, so that a LocalReview needs no Authenticated Account.
17. I want the parent of a matching Reply to stay visible, so that the Reply keeps its context.
18. I want the File Tree cursor to narrow the list, so that I review one area at a time.
19. I want the File Tree root entry to clear that filter, so that I see the whole Review again.
20. I want Enter to show the item's ReviewCard in the DiffPane, so that I read it with its code.
21. I want Enter to open a hiding disclosure, so that the jump always lands.
22. I want the Comment Overview to keep its Overview State, so that it works as a work queue.
23. I want the DiffPane to keep its cursor and scroll, so that `g d` returns me to my place.
24. I want Tab to move focus between the Sidebar and the Main Pane in both views.
25. I want a click to select an entry and a second click to open it, as in the Browser.
26. I want a Review-level Review Search result in the Comment Overview, so that it has clear context.
27. I want the Command Palette to list the new Actions, so that I find them without the keys.
28. I want to rebind every new Action in `[keymap]`, so that the keys fit my Keymap.
29. I want the status to show the Comment Overview keys, so that I learn them in place.
30. I want a Session replacement to show the DiffPane and a fresh Comment Overview, so that no stale entry survives.
31. I want a pure projection of the Session and the Drafts, so that fixtures prove it without a terminal.
32. I want the Comment Overview to list exactly the DiffPane ReviewCards, so that the two views never disagree.

## Decisions this spec records

The brief leaves these points to the spec.
Each item states the choice.

1. The Comment Overview is a new Pane, not a mode of the DiffPane.
   It has its own cursor, scroll, Interaction Context, and Title.
   The Main Pane is the Pane right of the Sidebar, and it shows the DiffPane or the Comment Overview.
2. The code keeps the names `layouts.PaneSlot.diff`, `frame.PaneFocus.diff`, and `frame.PaneRects.diff`.
   They now name the Main Pane.
   A rename would conflict with the M22 and M24 worktrees, so a doc comment records the meaning.
3. Newest first needs a time, but Comments and Drafts carry no timestamp.
   A Draft is newer than every Comment.
   Drafts compare by TempId, and Comments compare by CommentId.
   A Thread sorts by its newest member, and its Replies keep their Thread order.
4. The query filters entries and does not rank them.
   The chosen order stays.
5. An ancestor of a matching entry shows as a context entry, even when it does not match.
   A context entry is dim, and the Title count does not include it.
6. A Thread with a Draft root is unresolved.
7. Every Draft counts as mine in a RemoteReview and in a LocalReview.
   A Comment is mine when its `author_uuid` equals the Authenticated Account UUID.
8. While the Comment Overview shows, the File Tree starts with a root entry with the label "All Files".
   The File Tree cursor sets the File Tree Filter.
   A cursor move is a selection, so the filter follows each move.
9. Overview State belongs to the Session.
   A Session replacement, which includes `R`, a PullRequest switch, and Reconciliation, resets it and shows the DiffPane.
10. Inside the Comment Overview, `/` edits the query, and Enter opens the selected entry.
    `u` toggles unresolved only, `d` toggles Drafts only, and `a` toggles mine only.
    `o` toggles the order.
    No new binding uses `m` (M22), `b` or `s` (M24), or Escape.
11. `g o` and `g d` move focus to the Main Pane.
12. A File Jump always shows the DiffPane.
    Enter on a File Tree File while the Comment Overview shows is not a File Jump.
    It moves focus to the Comment Overview.
13. The Review Search route for a Review-level item clears only the Overview filters that hide the item.
14. Reply, edit, delete, and yank from the Comment Overview are out of scope.
    The reviewer uses Enter and acts on the ReviewCard.
15. The Comment Overview scroll bar sits in the padding ring of its entries, as in the Review Search Results list.

## Glossary changes

In the [Presentation glossary](../../src/tui/GLOSSARY.md):

- Add Main Pane:
  The Pane right of the Sidebar.
  It shows the DiffPane or the Comment Overview, never both.
  The DiffPane shows at start and after each Session replacement.
  _Avoid_: main area, main view, content Pane.
- Add Comment Overview:
  The Pane in the Main Pane that lists every Comment, Reply, and Draft of the current Review as Overview Entries.
  Its Overview State belongs to the Session.
  It never changes a disclosure.
  _Avoid_: comment list, conversations panel, ThreadPane, overview (alone).
- Add Overview Entry:
  One row of the Comment Overview.
  It names one Comment or Draft and sits one indent step under its parent.
  A context entry is a dim ancestor that does not match the filters.
  _Avoid_: item, row, result.
- Add Overview State:
  The query, the three toggles, the order, the File Tree Filter, the selection, and the scroll of the Comment Overview.
  The toggles are unresolved only, Drafts only, and mine only.
  The order is Review order or newest first.
  _Avoid_: overview settings, view state.
- Add File Tree Filter:
  The File Tree entry under the cursor while the Comment Overview shows.
  A File or a Directory narrows the Overview Entries to its path.
  The root entry clears it.
  _Avoid_: path filter, scope filter (Scope is a Diff term).
- Change Pane:
  Add the Comment Overview to the roles.
- Change File Tree:
  Add that a root entry leads the File Tree while the Comment Overview shows.
- Change File Jump:
  Add that a File Jump always shows the DiffPane.
  A File Tree File is a File Jump only while the DiffPane shows.
- Change Review Search:
  Add that a result for a Review-level Comment or Draft opens in the Comment Overview.
- Change Interaction Context:
  Add the Comment Overview and its query input as input surfaces.

In [GLOSSARY-MAP.md](../../GLOSSARY-MAP.md):

- Change "Review → Presentation":
  Add that Presentation projects every Comment and Draft as an Overview Entry without a second data source.

The Review glossary needs no change.

## Behavior

### Main Pane

`src/tui/presentation.zig` adds `pub const MainPane = enum { diff_pane, comment_overview };`.
`Published.main_pane` holds it.
`Published.createInputs` sets it to `.diff_pane`.

`Projection` and `frame.Projection` expose `main_pane`.
Every switch on `MainPane` is exhaustive.

`Published.focus` keeps `frame.PaneFocus`.
`.diff` means focus on the Main Pane, whichever Pane it shows.

### Actions and keys

`src/tui/action.zig` adds these Actions:

| Action | Default key | Interaction Contexts |
| --- | --- | --- |
| `show_comment_overview` | `g o` | `diff` and its inheriting contexts, `sidebar`, `sidebar_directory`, `sidebar_file`, `comment_overview` |
| `show_diff_pane` | `g d` | the same contexts |
| `open_overview_entry` | Enter | `comment_overview` |
| `edit_overview_query` | `/` | `comment_overview` |
| `toggle_overview_unresolved` | `u` | `comment_overview` |
| `toggle_overview_drafts` | `d` | `comment_overview` |
| `toggle_overview_mine` | `a` | `comment_overview` |
| `toggle_overview_order` | `o` | `comment_overview` |

`src/tui/action.zig` adds the Interaction Contexts `comment_overview` and `comment_overview_query`.

`Presentation.paneContext` returns `.comment_overview` when the Main Pane shows the Comment Overview and has focus.
`Presentation.interactionContext` returns `.comment_overview_query` while the query input is open.
`comment_overview_query` supports no Action, like `buffer_search_input`.

`keymap.supportsContext` accepts these existing Actions in `comment_overview`:

- The Motions `down`, `up`, `half_page_down`, `half_page_up`, `page_down`, and `page_up`.
- The Motions `to_top`, `to_bottom`, `center`, `cursor_view_top`, `cursor_view_middle`, and `cursor_view_bottom`.
- The Motions `scroll_row_up` and `scroll_row_down`.
- `quit`, `help`, `open_command_palette`, `open_theme_overlay`, and `open_pull_request_picker`.
- `open_file_finder`, `open_review_search`, `refresh`, and `review_comment`.
- `set_verdict_approved`, `set_verdict_changes_requested`, and `set_verdict_none`.
- `submit`, `recover_submission`, and `focus_next_pane`.

`show_comment_overview` does nothing when the Comment Overview already shows.
`show_diff_pane` does nothing when the DiffPane already shows.
Neither one shows a status message in that case.

`keymap.validateBindings` accepts the defaults because the shared chords have no shared context.
Some keys have two Actions with disjoint contexts.
`o` is isolate and order, and `/` is Buffer Search and the query.
`a` is re-anchor and mine, and Enter has several Actions too.
`g o` and `g d` are not prefixes of another binding.

A `[keymap]` override can rebind or unbind each new Action by its exact name.

ActionAvailability refuses every new Action without a published Review.
While a Session replacement loads, the new Actions are Session-specific and follow the existing suspension rule.

### Showing and hiding

`show_comment_overview` runs these steps:

1. If `Published.main_pane` is `.comment_overview`, it stops.
2. It builds the Overview Index if the index is stale.
   An allocation failure keeps the DiffPane and reports `out_of_memory`.
3. It rebuilds the File Tree with the root entry.
   It puts the File Tree cursor on the entry of the stored File Tree Filter, or on the root entry.
4. It builds the Overview Listing from the index and the Overview State.
5. It sets `main_pane` to `.comment_overview` and `focus` to `.diff`.
6. It cancels a pending Overview destination, as the "Stale work" section describes.

Steps 2 to 4 stage their results.
The step 5 publication is infallible, so a failure leaves the previous Presentation Frame.

`show_diff_pane` runs these steps:

1. If `Published.main_pane` is `.diff_pane`, it stops.
2. It sets `main_pane` to `.diff_pane` and `focus` to `.diff`.
3. It rebuilds the File Tree without the root entry.
4. It calls `revealActiveFile`, so the File Tree cursor follows the active File again.
5. It cancels a pending Overview destination.

The DiffPane Buffer, `Published.navigation`, the Selection, and Buffer Search stay as they are while the Comment Overview shows.
So `g d` returns to the exact DiffPane cursor and scroll.

### Overview Index and Overview Listing

`src/tui/comment_overview.zig` is a new module.
It imports neither vaxis nor `theme.zig`.
It owns two pure builds.

`comment_overview.Index` holds one record for each Comment and Draft that the DiffPane shows as a ReviewCard.
`comment_overview.buildIndex(allocator, inputs: IndexInputs) !Index` builds it.
`IndexInputs` holds `session.threads`, the PendingReview Drafts, the ScopeProjection, `session.diff`, the mention names, the Authenticated Account UUID, and the review kind.

`comment_overview.Listing` is the ordered, filtered list of Overview Entries.
`comment_overview.buildListing(allocator, index: *const Index, state: *const State) !Listing` builds it.

`Published.overview_index` and `Published.overview_listing` hold the published results.
Each one lives in its own `ArenaRing(2)`, so a failed build keeps the previous result.

Presentation rebuilds the index when a Draft, a Draft state, or the ScopeProjection changes.
It rebuilds only while the Comment Overview shows.
While the DiffPane shows, it marks the index stale, and `show_comment_overview` rebuilds it.
Presentation rebuilds the listing after an index rebuild and after each Overview State change.
Neither build depends on the terminal width, so a resize rebuilds nothing.

### Which items the index lists

The index lists exactly the Comments and Drafts that `buffer.buildWithComments` shows as ReviewCards when every disclosure is open.
It does not read `Published.expanded_disclosures`, and it never changes it.

- A Comment of every Thread is listed, also when the Thread is resolved and collapsed.
- A Deleted Comment is listed with its author.
- A Draft in the `submitting` state is not listed, because the DiffPane hides it.
- A Draft in the `posted` state is listed until the fetched Comment with its CommentId exists.
  Then only the Comment is listed.
- An outdated, moved, or unavailable item is listed with its ScopeState.
- A ReviewCard with a collapsed body is listed.

`buffer.zig` exports the parent resolution that `Weave` uses, including the `ParentIndex` alias for a posted Draft.
`buildIndex` calls it, so the two views always agree on parents and posted aliases.

Each `comment_overview.Record` holds:

- `owner: review_card.Owner`, the stable identity of the Comment or Draft.
- `parent: ?review_card.Owner`.
- `depth: usize`, which is 0 for a root.
- `role: review_card.CardRole`, the same role that the ReviewCard has.
- `author: []const u8`, in the ReviewCard Title format of `buffer.cardTitle`.
  A Comment shows its author.
  A Draft shows `✎ draft`.
  States follow in parentheses, as in `Ada (deleted, suggestion)` or `✎ draft (outcome unknown)`.
- `scope: bbr.review.CommentScope`, the projected scope of the Thread root.
- `scope_state: ?bbr.review.ScopeState`, or null for `unavailable`.
- `resolved: bool`, the resolved flag of the Thread.
  A Thread with a Draft root is not resolved.
- `mine: bool`.
- `excerpt: []const u8`.
- `haystack: []const u8`, the author, the scope path, and the authored body, joined with newlines.
- `review_rank` and `recency_rank`, the positions in each order.

The index copies every string into its own arena.
It borrows nothing from the Session or the PendingReview.

The excerpt is the first non-blank prose line of the ReviewBody, with mention names applied.
It collapses each run of whitespace into one space.
It stops at 200 bytes on a UTF-8 scalar boundary.
A body with only a Suggestion fence has the excerpt "suggestion".
A Deleted Comment without a body has an empty excerpt.

### Order

Review order is the default.
It sorts the Threads, and each Thread keeps its own Reply order.

1. Review-level Threads come first.
2. Then Threads of Files come in File Tree order, which is `file_tree.build` path order.
3. In one File, File-level Threads come before inline Threads.
4. Inline Threads sort by `Anchor.top()`.
   At the same line number, an old-side Anchor comes before a new-side Anchor.
5. Threads at the same place sort by Comment input order (`Thread.root_input_order`), then by Draft TempId.
   Comment Threads come before Draft Threads.
6. A Thread whose path matches no File of the Session comes after every File, sorted by path.

Inside a Thread, the Replies follow the same order as `Weave.emitRepliesTo` in `src/tui/buffer.zig`.

Newest first sorts the Threads by the recency of their newest member.
A Draft is newer than every Comment.
A larger TempId is newer than a smaller TempId.
A larger CommentId is newer than a smaller CommentId.
Inside a Thread, the Replies keep their Review-order sequence, so the nesting stays intact.

`toggle_overview_order` switches between the two orders.

### Filters

The Overview State holds these filters:

- `query`: the fuzzy query text, at most 256 bytes.
- `unresolved_only`: keep only items of Threads that are not resolved.
- `drafts_only`: keep only Drafts.
- `mine_only`: keep only items that are mine.
- `file_tree_filter: ?file_tree.Identity`: keep only items whose scope path is under the entry.

An item matches when it passes every active filter.
The filters combine with AND.

The query uses `list_overlay.Query`.
A trimmed blank query matches every item.
Otherwise, the item matches when `Query.rank(record.haystack)` is not null.
The rank only decides the match, and the order does not change.

A Draft is always mine.
A Comment is mine when its `author_uuid` equals `Presentation.authenticated_account_uuid`.
Without a known Authenticated Account, no Comment is mine.

The File Tree Filter compares the scope path of the Thread root:

- A File entry matches an item when `pathMatchesFile` accepts the scope path for that File.
- A Directory entry matches an item when the scope path starts with the Directory path and a `/`.
- A Review-level item matches only the root entry.

The listing shows each matching item.
It also shows every ancestor of a matching item as a context entry.
A context entry is selectable, and Enter opens it.

The listing counts the matching entries and the index records.
The Title shows both counts.

### Query input

`edit_overview_query` opens the query input.
It saves the current query as the restore point.

While the query input is open, Presentation reads keys as Buffer Search does:

- Text inserts at the end.
- Backspace deletes one scalar.
- `ctrl-w` deletes one word.
- `ctrl-u` deletes the whole query.
- Enter closes the input and keeps the query.
- Escape and `ctrl-c` close the input and restore the saved query.

Each edit rebuilds the listing at once.
An allocation failure keeps the previous listing and the previous query and reports `out_of_memory`.

### Selection and scroll

`State.selected: ?review_card.Owner` names the selected entry by identity.
`State.scroll: usize` is the first visible entry.

After each listing rebuild, Presentation keeps the selection on the same Owner when the listing still shows it.
Otherwise, it selects the next entry in the old order that the listing still shows.
If no such entry exists, it selects the last entry.
An empty listing has no selection.

The scroll keeps its top entry until the selection leaves the viewport.
Then the scroll moves the minimum distance that shows the selection.

The Motions work on the listing as the DiffPane Motions work on the Buffer.
A Count applies to `down` and `up`.

### Layout and painting

`src/tui/layouts.zig` adds `layouts.commentOverviewPanes`.

```zig
pub const OverviewPaneSlot = enum { sidebar, overview, filter, entries };

pub const OverviewPanes = struct {
    sidebar_focused: bool = false,
    sidebar_scroll: Scroll = .{},
    title: []const u8 = "",
    entries_scroll: Scroll = .{},
};
```

The tree has the same `sidebar` Composition and the same Sidebar View as `layouts.panes`.
One shared function builds the Sidebar View for both trees.
The `overview` View has a rounded border with the Title in its top border.
Its content is a flow of three Views:

1. The `filter` row, one cell high.
2. A rule that joins the Pane border with `├` and `┤`.
3. The `entries` View, which fills the rest.
   Its scroll bar sits in its padding ring and is always declared.

`frame.overviewRects(geometry)` solves this tree, like `frame.paneRects`.
The Sidebar rect and the `overview` border rect equal the `sidebar` and `diff` border rects of `layouts.panes` at every size.

The Title is `Comment Overview <matches>/<records>`, as in `Comment Overview 12/40`.

`render.drawCommentOverview` paints the filter row and the entries into their content rects.
`view_paint.zig` paints the border, the Title, the rule, and the scroll bar.
`app.zig` paints `layouts.panes` or `layouts.commentOverviewPanes` through an exhaustive switch on `MainPane`.

### The filter row

The filter row is a repel of the query on the left and the filter chips on the right.

- The query part shows `/`, then the query text.
  An empty query shows the muted placeholder "filter".
  While the query input is open, a cursor cell follows the text.
- The chips are `u unresolved`, `d drafts`, `a mine`, and `o review order` or `o newest first`.
  An active toggle chip paints in the active chip style, and an inactive one paints muted.
- A File Tree Filter adds the chip `in <path>` before the other chips.
  A Directory path ends with `/`.

When the row is too narrow, the chips shrink from the end, as `repel` without `wrap` does.

### Overview Entry rows

Each Overview Entry is one terminal row.
From left to right, the row has these parts:

1. The indent: two cells for each depth step, with at most eight steps.
2. For a resolved Thread root, `✓ ` in the resolved style.
3. The author label.
4. For a root entry, two cells, then the scope label.
5. Two cells, then the excerpt.

The scope label is one of these:

- `Review` for a Review-level item.
- The path for a File-level item.
- `<path>:L<n>` for a one-line inline item, or `<path>:L<top>-L<bottom>` for a range.
- An old-side Anchor adds ` old`.
- A ScopeState other than `current` adds ` (moved)` or ` (outdated)`.
  `unavailable` adds ` (unavailable)`.

A path longer than 40 cells loses its start, and `…` takes the first cell.
The row stops at the content edge, and `…` takes the last cell of a cut row.
`render.drawCommentOverview` measures cells with the Frame `CellMetrics`.

A context entry paints every part in the context style.
The selected entry paints the cursor band across the whole content width.

An empty index shows "No Comments or Drafts in this Review" in the muted style.
An empty listing with a nonempty index shows "No entry matches the filters".

### Theme

`src/tui/theme.zig` adds `pub const OverviewPart = enum { author, scope, excerpt, resolved, context, query, placeholder, chip, chip_active, message };`.
It adds `Theme.overviewStyle(part: OverviewPart, role: review_card.CardRole) Style` with an exhaustive switch.

- `author` takes the foreground of the role's ReviewCard header style.
- `resolved` takes the foreground of `Theme.resolvedThreadStyle`.
- `context` takes `card_border_dim`.
- `chip_active` takes the accent foreground in bold.
- `placeholder`, `chip`, and `message` take the muted foreground.

Every part has the Theme base background.
The `comptime` block after `theme.value` checks this for every built-in Theme, every part, and every role.
The selected entry takes `Theme.cursorBg` of the base background.
M29 adds no Theme field.

### Focus and Tab

`focus_next_pane` moves focus between the Sidebar and the Main Pane, whichever Pane it shows.

While the Comment Overview shows, `focusPane` does not call `cursorToActiveFile`.
The File Tree cursor stays on the File Tree Filter.
`revealActiveFile` moves the File Tree cursor only while the DiffPane shows and has focus.

### File Tree Filter

`file_tree.Identity` adds the arm `root`.
`file_tree.build` takes `root_entry: bool`.
When it is true, the first entry is the root entry at depth 0 with the label "All Files".
Its tally is the sum of every File tally.
The other entries keep their depth, so their indent does not change between views.

`Presentation.paneContext` returns `.sidebar` for the root entry.

While the Comment Overview shows, each File Tree cursor move sets `State.file_tree_filter` to the entry under the cursor.
The root entry sets it to null.
A Directory collapse that moves the cursor to the parent Directory sets the filter to that Directory.
Each change rebuilds the listing.

While the Comment Overview shows, `focus_file` on a File entry moves focus to the Main Pane.
It does not start a File Jump.
A click on a File entry does the same.

A File Jump always shows the DiffPane.
`open_file_finder` in the `comment_overview` context opens the File Finder.
Its choice sets `main_pane` to `.diff_pane` and then runs the existing File Jump.

### Opening an Overview Entry

`open_overview_entry` opens the selected entry.
With no selected entry, ActionAvailability refuses it with `no_review_item`.

Presentation finds the ReviewCard destination as `openReviewSearchOccurrence` does for a ReviewBody occurrence:

- A Review-level item ends File isolation.
- An item in another File moves an active isolation to that File.
- An inline item that is not outdated sets Selected Version to the side of its Anchor.
- The required disclosures are the resolved Thread and the outdated File or Review section.
  They also include the opposite version section and the Fold that holds the anchored Line.
  `disclosureChain` and `sourceFoldDisclosure` in `src/tui/presentation.zig` name them.
- A collapsed ReviewCard body stays collapsed, because its header row is always visible.

Presentation queues one `DisclosureBuild` with the new kind `overview_destination`.
It reuses the admission checks of `review_destination`: Session Epoch, geometry, enrichment revision, and generation.
The job carries `overview_destination_id` from `Published.overview_destination_generation`.

The build finds the destination row as the first visual row whose `RowOwner` is the entry's Owner with `Part.header`.
On acceptance, Presentation publishes the Buffer and these changes in one infallible step:

1. `main_pane` becomes `.diff_pane`.
2. The DiffPane cursor moves to the destination row, and the view centers it.
3. `revealActiveFile` runs.

The Overview State does not change.
So `g o` shows the same query, filters, order, selection, and scroll.

When the build finds no destination row, the Comment Overview stays and the status shows `overview_entry_unavailable`.
A failed build keeps the Comment Overview and shows `buffer_build_failed`.

### Stale work

- Each Overview destination carries the Session Epoch.
  After a Session replacement, Presentation destroys the job and changes nothing.
- A second `open_overview_entry` increments `overview_destination_generation`.
  Only the latest destination can publish.
- `show_diff_pane`, `show_comment_overview`, and an opened File Finder choice increment the generation too.
  So a pending destination never moves a later view.
- A changed geometry or enrichment revision retries the build, as for `review_destination`.
- A filter, query, order, or selection change does not cancel a pending destination.
- The index and the listing build on the main thread inside one dispatch.
  They have no worker, so they have no stale completion.

### Session replacement

The Overview State, the index, the listing, and `main_pane` live in `Published`.
A Session replacement publishes a new `Published` that shows the DiffPane.
Its Overview State has an empty query, no active toggle, and Review order.
It has no File Tree Filter, no selection, and scroll 0.
The old ones go with the old `Published`.

While a Candidate Session loads, the Comment Overview keeps showing the old Session.
A failed replacement keeps the old `Published`, so the Comment Overview and its Overview State stay.

The rule "The File Finder and the Command Palette close before Session replacement" holds without change.
The query input closes with its `Published`.

### Review Search route

`openReviewSearchOccurrence` changes for a ReviewBody occurrence whose current scope is `.review`.
It no longer queues a `review_destination`.
It runs these steps:

1. It closes Review Search.
2. It builds the index if the index is stale.
3. It clears each Overview filter that hides the item.
   A query, a toggle, and a File Tree Filter each count.
   The order stays.
4. It shows the Comment Overview as `show_comment_overview` does.
5. It selects the item's Owner and scrolls it into view.

When step 3 clears a filter, the status shows `overview_filters_cleared`.
Every other occurrence keeps the M21 route.
When that route publishes, `main_pane` becomes `.diff_pane`.

`open_review_search` in the `comment_overview` context opens Review Search over the Comment Overview.

### Mouse

`frame.HitTarget` adds `overview_entry: usize`.
`frame.hitTest` returns it for a cell in the `entries` content rect while the Comment Overview shows.

- A click on an entry moves focus to the Main Pane and selects the entry.
- A click on the entry that is already selected runs `open_overview_entry`.
- The wheel scrolls the listing by `mouse_vertical_scroll_rows`, like the Panes.
- A click on the filter row moves focus to the Main Pane.

### Status

While the Comment Overview shows, the meta part keeps its items.
The position item shows `<selected>/<entries>` for the listing.
Its width reserve is the width of `<entries>/<entries>`.

The hint part swaps the DiffPane hints for these hints:

- `/` with " filter".
- `↵` with " open".
- `g d` with " DiffPane".
- The `X` submit hint, when Drafts exist.
- `?` with " help".
- `q` with " quit".

The DiffPane hint part adds `g o` with " comments".

`layouts.StatusSlot` adds the hint arms `filter`, `open`, and `main_pane`.
The status height can change when the Main Pane changes.
`syncContentGeometry` sends the new content geometry, as for any status text change.

M29 adds two `ActionError` values with their `actionErrorText` texts in `src/tui/app.zig`:

- `overview_entry_unavailable`: "The entry is no longer in the Review".
- `overview_filters_cleared`: "Comment Overview filters cleared to show the entry".

The status paints them through the existing `Theme.statusStyle` parts.

### Command Palette

`CommandPalette.pane_contexts` in `src/tui/list_overlay.zig` adds `.comment_overview`.
The Command Palette adds these entries:

| Action | Title | Description |
| --- | --- | --- |
| `show_comment_overview` | Show Comment Overview | List every Comment, Reply, and Draft in this Review |
| `show_diff_pane` | Show DiffPane | Show the diff in the Main Pane |
| `open_overview_entry` | Open in DiffPane | Show the selected entry's ReviewCard in the DiffPane |
| `edit_overview_query` | Filter Comments | Type a query over author, body, and path |
| `toggle_overview_unresolved` | Unresolved Only | Show only unresolved Threads |
| `toggle_overview_drafts` | Drafts Only | Show only Drafts |
| `toggle_overview_mine` | Mine Only | Show only your Comments and Drafts |
| `toggle_overview_order` | Toggle Comment Order | Switch between Review order and newest first |

The description of "Switch Pane" becomes "Move focus between the Sidebar and the Main Pane".

### Help Overlay

The help Overlay lists the new bindings with these help texts:

- "show Comment Overview" and "show DiffPane".
- "open entry in DiffPane" and "filter Comment Overview".
- "unresolved only", "Drafts only", and "mine only".
- "toggle Comment order".

## Data model

The new module `src/tui/comment_overview.zig` holds these types:

```zig
pub const Order = enum { review, newest_first };

pub const State = struct {
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    unresolved_only: bool = false,
    drafts_only: bool = false,
    mine_only: bool = false,
    order: Order = .review,
    file_tree_filter: ?file_tree.Identity = null,
    selected: ?review_card.Owner = null,
    scroll: usize = 0,
};

pub const Entry = struct {
    record: usize,
    context: bool,
};

pub const Listing = struct {
    entries: []const Entry,
    matches: usize,
    records: usize,
};
```

A Directory in `file_tree_filter` borrows its path from the File Tree.
Presentation copies it into the `Published` allocator when it stores the filter.

`Published` adds `main_pane`, `overview: comment_overview.State`, `overview_query_input: ?QueryInput`, `overview_index`, `overview_listing`, `overview_index_stale`, and `overview_destination_generation`.

No SQLite table, config key, or file changes.

## Affected modules

| Module | Change |
| --- | --- |
| `src/tui/comment_overview.zig` (new) | `State`, `Order`, `Record`, `Index`, `buildIndex`, `Entry`, `Listing`, and `buildListing`. |
| `src/tui/buffer.zig` | Export the Weave parent resolution and the posted-Draft alias for `buildIndex`. |
| `src/tui/review_body.zig` | A helper that returns the first prose line of a ReviewBody. |
| `src/tui/presentation.zig` | `MainPane`, the `Published` fields, the new Actions, the query input, `DisclosureBuild.Kind.overview_destination`, the Review Search route, focus rules, and two `ActionError` values. |
| `src/tui/action.zig` | Eight Actions and two Interaction Contexts. |
| `src/tui/keymap.zig` | Default bindings, help texts, and `supportsContext` arms. |
| `src/tui/list_overlay.zig` | The Command Palette entries and `pane_contexts`. |
| `src/tui/file_tree.zig` | `Identity.root` and the `root_entry` parameter of `build`. |
| `src/tui/layouts.zig` | `layouts.commentOverviewPanes`, the shared Sidebar View, and three `StatusSlot` arms. |
| `src/tui/frame.zig` | `overviewRects`, `Projection.main_pane`, and `HitTarget.overview_entry`. |
| `src/tui/render.zig` | `drawCommentOverview` and the root entry in `drawFileTree`. |
| `src/tui/theme.zig` | `OverviewPart`, `Theme.overviewStyle`, and the `comptime` check. |
| `src/tui/app.zig` | The Main Pane paint switch, the status hints, and the `actionErrorText` texts. |
| `src/main.zig` | Import `comment_overview.zig` in the test chain. |
| `build.zig` | A `test-comment-overview` target with the filter `M29 overview`. |
| Glossaries, `GLOSSARY-MAP.md`, `src/tui/IMPLEMENTATION.md`, `README.md`, `AGENTS.md`, `TODO.md` | Documentation changes in ticket 06. |

## AGENTS.md rules

M29 touches these existing rules:

- "A terminal surface is a View tree in `src/tui/layouts.zig`."
  The Comment Overview is `layouts.commentOverviewPanes`, and `drawCommentOverview` paints only content.
- "A Pane has rounded corners and its Title in the top border."
  The Comment Overview follows it.
  Its first body row is the filter row, so no rule sits under the Title.
- "The Sidebar and the DiffPane touch."
  The Comment Overview takes the DiffPane rect, so the Sidebar and the Comment Overview touch too.
- "Every Title has one blank cell on each side."
  The Comment Overview Title goes through the View tree Title.
- "A layout tree always declares its scroll bars."
  `layouts.commentOverviewPanes` declares the Sidebar and entries scroll bars on every solve.
- "A layout tree places each of its Slots exactly once."
  The test "every layout places each of its Slots" adds `layouts.commentOverviewPanes`.
- "`presentation.zig` does not import vaxis or `theme.zig`."
  `comment_overview.zig` follows the same rule.
- "The File Finder and the Command Palette close before Session replacement."
  It holds without change.
- "A File Jump calls `Published.jumpToFileHeader`."
  M29 changes the text: a File Jump also shows the DiffPane.
  A File Tree File is a File Jump only while the DiffPane shows.
  The test "M29 overview a File Jump shows the DiffPane" proves it.
- "While the DiffPane has focus, the File Tree cursor follows the active File."
  M29 changes the text: this holds while the DiffPane shows and has focus.
  The test "M29 overview the File Tree cursor stays on the File Tree Filter" proves it.
- "The status paints each part through `Theme.statusStyle`."
  The new hints use the existing `key` and `hint` parts.
- The Command Palette `comptime` block in `src/tui/list_overlay.zig` must accept the new entries.
  No new entry is a Motion, and a Pane context supports each one.

M29 adds these rules to the table in ticket 06:

| Rule | Enforcement |
| --- | --- |
| The Main Pane shows the DiffPane or the Comment Overview, never both. `Published.main_pane` decides it. A Session replacement shows the DiffPane and resets the Overview State. | The exhaustive switch on `MainPane` in `src/tui/app.zig` (compile error). The tests "M29 overview the Main Pane paints one Pane at a time" in `src/tui/render.zig` and "M29 overview a Session replacement shows the DiffPane and resets the Overview State" in `src/tui/presentation.zig`. |
| The Comment Overview lists exactly the Comments and Drafts that the DiffPane shows as ReviewCards with every disclosure open. Listing never changes a disclosure. | The tests "M29 overview the index lists the DiffPane ReviewCards with every disclosure open" in `src/tui/comment_overview.zig` and "M29 overview showing the Comment Overview changes no disclosure" in `src/tui/presentation.zig`. |
| An Overview Entry names its Comment or Draft by `review_card.Owner`. `open_overview_entry` puts the DiffPane cursor on that Owner's ReviewCard header row. | The test "M29 overview Enter puts the ReviewCard header under the cursor for every CommentScope" in `src/tui/presentation.zig`. |
| The Comment Overview paints the Theme base background. Only the selected entry carries its own background. | The `comptime` block after `theme.value` in `src/tui/theme.zig` (compile error). The test "M29 overview paints the Theme base background" in `src/tui/render.zig`. |
| The Comment Overview has the Sidebar and Main Pane rects of `layouts.panes` at every size. | The test "M29 overview the Comment Overview Panes match the DiffPane Panes at every size" in `src/tui/layouts.zig`. |

## Testing Decisions

A good test asserts behavior that the reviewer can observe.
Tests assert listed Owners and their order, depths, labels, published Projection fields, emitted commands, status messages, and rendered cells.
Tests do not assert arena indices, `ArenaRing` slots, or private helper calls.

Every new test name starts with `M29 overview`, so `zig build test-comment-overview` runs them.

### Seams

- `comment_overview.buildIndex` and `comment_overview.buildListing` are pure.
  Fixtures build Threads and Drafts in memory, as the `buffer.zig` tests do.
- The Presentation transition is the integration seam, as in ADR-0012.
  Tests dispatch keys, Actions, completions, and Session replacements, and they inspect the Projection.
- Headless rendering is the secondary seam for cells and styles.

### Prior art

- The `M23 ancestry` tests in `src/tui/buffer.zig` and `src/tui/render.zig` for ReviewCard parents and posted aliases.
- The `M21 kernel` and `M21 authored` tests in `src/tui/presentation.zig` for Review Search destinations and stale disclosure builds.
- "every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File" in `src/tui/presentation.zig`.
- "every layout places each of its Slots" and "the Panes touch with no gap and a 28-cell Sidebar" in `src/tui/layouts.zig`.
- "every Overlay paints the Theme base background" and "a ReviewCard paints the Theme base background" in `src/tui/render.zig`.
- The Command Palette and `[keymap]` override tests in `src/tui/list_overlay.zig` and `src/tui/keymap.zig`.
- The allocation-failure tests that use `testing.checkAllAllocationFailures` in `src/tui/presentation.zig`.

### Test plan

Index and listing:

- The index lists a Review-level Comment, a File-level Comment, a new-side inline Comment, an old-side inline Comment, and a range.
- The index lists a Reply at depth 1 and a Reply to a Reply at depth 2.
- The index lists a Draft root, a Draft Reply to a Comment, and a Draft Reply to a Draft.
- The index lists a resolved Thread, a Deleted Comment, and outdated, moved, and unavailable items.
- The index hides a `submitting` Draft and lists a `posted` Draft until its Comment is fetched.
- "M29 overview the index lists the DiffPane ReviewCards with every disclosure open" compares the Owners and parents with `buffer.buildWithComments`.
- Review order puts Review-level Threads first, then Files in File Tree order, then Lines.
- Newest first puts a Draft Thread before Comment Threads and keeps Replies under their parents.
- The query matches the author, the body, and the path, and a blank query matches every item.
- Each toggle keeps only matching items, and the toggles combine with AND.
- An unresolved-only filter keeps a Draft-root Thread.
- Mine-only keeps every Draft in a LocalReview and in a RemoteReview.
- Mine-only keeps a Comment only when its `author_uuid` equals the Authenticated Account.
- A matching Reply shows its non-matching parent as a context entry.
- The Title counts exclude context entries.
- The excerpt applies mention names, collapses whitespace, and stops at 200 bytes on a scalar boundary.

Presentation:

- `g o` shows the Comment Overview, and `g o` again changes nothing.
- `g d` shows the DiffPane with the same cursor, scroll, and Selection as before `g o`.
- `g d` in the DiffPane changes nothing.
- `g o` after `g d` shows the same query, filters, order, selection, and scroll.
- "M29 overview showing the Comment Overview changes no disclosure".
- Tab moves focus between the Sidebar and the Comment Overview.
- The Motions and a Count move the selection, and the scroll follows it.
- A saved Draft appears in the Comment Overview, and the selection keeps its Owner.
- A filter change that hides the selected entry selects the next shown entry.
- The query input inserts, deletes, accepts with Enter, and restores with Escape.
- An allocation failure in an index or listing build keeps the previous Frame.
- "M29 overview Enter puts the ReviewCard header under the cursor for every CommentScope".
- Enter on a collapsed resolved Thread opens only its resolved Thread disclosure.
- Enter on an outdated item opens its outdated section.
- Enter on an item in another File moves an active isolation to that File.
- Enter on a Review-level item ends File isolation.
- A second Enter supersedes a pending destination.
- `g d` during a pending destination keeps the DiffPane cursor where it was.
- A Session replacement during a pending destination destroys the job and changes nothing.
- "M29 overview a Session replacement shows the DiffPane and resets the Overview State".
- A failed Session replacement keeps the Comment Overview and its Overview State.
- The File Tree shows the root entry only while the Comment Overview shows.
- A File Tree cursor move sets the File Tree Filter, and the root entry clears it.
- A Directory File Tree Filter keeps items of every File under the Directory.
- "M29 overview the File Tree cursor stays on the File Tree Filter".
- Enter on a File Tree File while the Comment Overview shows moves focus to the Comment Overview.
- "M29 overview a File Jump shows the DiffPane".
- A Review-level Review Search result shows the Comment Overview with the item selected.
- That route clears only the filters that hide the item and reports `overview_filters_cleared`.
- A source Review Search result shows the DiffPane when it publishes.
- A click selects an entry, and a click on the selected entry opens it.

Rendering and layout:

- "M29 overview the Comment Overview Panes match the DiffPane Panes at every size".
- "every layout places each of its Slots" covers `layouts.commentOverviewPanes`.
- The Comment Overview has rounded corners, its Title in the top border, and a rule that joins the border.
- "M29 overview the Main Pane paints one Pane at a time".
- "M29 overview paints the Theme base background" for every built-in Theme.
- An entry row shows the indent, the resolved mark, the author, the scope label, and the excerpt.
- A narrow row cuts the path start and the row end with `…`.
- The filter row shows the active chips and the File Tree Filter chip.
- The status shows the Comment Overview hints and the listing position.

Keymap and Command Palette:

- `g o`, `g d`, `/`, `u`, `d`, `a`, `o`, and Enter resolve to the new Actions in their contexts.
- The default Keymap passes `validateBindings`.
- A `[keymap]` override can rebind and unbind each new Action.
- The Command Palette lists the new entries from the DiffPane, the Sidebar, and the Comment Overview.

### Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`, and the reported test count increases.
- `python3 tools/check_agent_docs.py`

The live outside check in ticket 07 is a manual acceptance step.
It does not gate the hermetic suite.

## Implementation tickets

1. [Show the Comment Overview in place of the DiffPane](issues/01-show-the-comment-overview-in-place-of-the-diffpane.md)
2. [Open an Overview Entry at its ReviewCard](issues/02-open-an-overview-entry-at-its-reviewcard.md)
3. [Filter and order the Comment Overview](issues/03-filter-and-order-the-comment-overview.md)
4. [Narrow the Comment Overview from the File Tree](issues/04-narrow-the-comment-overview-from-the-file-tree.md)
5. [Route Review-level Review Search results through the Comment Overview](issues/05-route-review-level-review-search-results-through-the-comment-overview.md)
6. [Document M29 and verify the integrated suite](issues/06-document-m29-and-verify-the-integrated-suite.md)
7. [Run the live M29 outside check](issues/07-run-the-live-m29-outside-check.md)

## Out of Scope

- Source context for an inline item, File context for a File-level item, and ReviewHeader context for a Review-level item.
  Decision 8 of the brief defers them.
- A right Sidebar or a responsive layout.
- A config key for the start view.
- Reply, edit, delete, re-anchor, and yank from the Comment Overview.
- A resolve or unresolve Action for a Thread.
- Match highlights for the query in the entry rows.
- Persistence of the Overview State across a Session replacement or a restart.
- A Comment timestamp from Bitbucket.
- A rename of the `diff` names in `layouts.PaneSlot`, `frame.PaneFocus`, and `frame.PaneRects`.

## Further Notes

- ADR-0012 holds.
  The Overview State is Session-relative state, so a Session replacement resets it.
  Each build stages its result and publishes through an infallible step.
- ADR-0013 holds.
  The Comment Overview is a View tree, and `view_paint.zig` paints its decoration.
- M22 binds `m` to `toggle_file_read` in the Sidebar and DiffPane contexts.
  M29 does not bind `m`.
  Whichever milestone lands second checks that `toggle_file_read` stays unavailable in `comment_overview`, or adds it on purpose.
- M24 binds `b` to `open_browser` in the Sidebar and DiffPane contexts.
  Whichever milestone lands second decides whether `open_browser` also works in `comment_overview`.
  The Browser replaces the whole content region, so the Comment Overview hides under it and keeps its Overview State.
- The TODO line "Show nearby source Lines for an inline item" stays open as deferred work.
  Ticket 06 marks it as deferred in `TODO.md`.
