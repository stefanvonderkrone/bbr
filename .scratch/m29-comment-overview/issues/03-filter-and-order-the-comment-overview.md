# 03: Filter and order the Comment Overview

Status: resolved
Blocked by: 01
Spec: [M29 spec](../SPEC.md)

## What to build

A reviewer narrows the Comment Overview to what still needs action.
`/` opens a fuzzy query over author, body, and path.
`u` keeps unresolved Threads, `d` keeps Drafts, and `a` keeps items that are mine.
`o` switches between Review order and newest first.
A matching Reply keeps its parent visible as a dim context entry.
The filter row shows the query and which toggles are active.
The filters, the query, and the order survive `g d` and `g o`.

## Scope

- Add the Actions `edit_overview_query`, `toggle_overview_unresolved`, `toggle_overview_drafts`, `toggle_overview_mine`, and `toggle_overview_order` with `/`, `u`, `d`, `a`, and `o`.
- Add the Interaction Context `comment_overview_query` and the query input key handling in `Presentation.applyKey`.
- Add the filters, the context entries, the newest-first order, and the match counts to `comment_overview.buildListing`.
- Use `Presentation.authenticated_account_uuid` for mine-only Comments.
- Paint the query, the placeholder, the cursor cell, and the chips in the filter row.
- Show "No entry matches the filters" for an empty listing with a nonempty index.
- Add the `/ filter` status hint.
- Add the Command Palette entries "Filter Comments", "Unresolved Only", "Drafts Only", "Mine Only", and "Toggle Comment Order".
- Add the matching help texts.

## Acceptance criteria

- [x] The query matches the author, the body, and the path, and a blank query matches every item.
- [x] The query filters and does not change the order.
- [x] Each toggle keeps only matching items, and the toggles combine with AND.
- [x] Unresolved only keeps a Draft-root Thread and drops a resolved Comment Thread.
- [x] Mine only keeps every Draft in a LocalReview and in a RemoteReview.
- [x] Mine only keeps a Comment only when its `author_uuid` equals the Authenticated Account.
- [x] Without a known Authenticated Account, mine only keeps no Comment.
- [x] A matching Reply shows its non-matching ancestors as dim context entries.
- [x] The Title counts exclude context entries.
- [x] Newest first puts a Draft Thread before Comment Threads and sorts Comment Threads by their newest CommentId.
- [x] Newest first keeps each Reply under its parent.
- [x] The query input inserts text and deletes with Backspace, `ctrl-w`, and `ctrl-u`.
- [x] Enter keeps the edited query, and Escape restores the saved query.
- [x] A filter change that hides the selected entry selects the next shown entry.
- [x] An allocation failure during a query edit keeps the previous listing and query.
- [x] `g d` and `g o` keep the query, the toggles, and the order.
- [x] The filter row shows the active chips in the active style and the inactive chips muted.
- [x] The default Keymap passes `validateBindings` with the new bindings.
- [x] A `[keymap]` override can rebind and unbind each new Action.
- [x] The Command Palette lists the five entries from the Comment Overview.

## Tests that prove it

- Listing fixtures in `src/tui/comment_overview.zig`.
- Presentation tests in `src/tui/presentation.zig`.
- Render tests for the filter row in `src/tui/render.zig`.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`

## Comments

- `Record.recency_rank` is new. `buildIndex` gives each Thread the recency of its newest member and sorts the Threads by it. A Draft is newer than every Comment. The Replies keep their Review order.
- `buildListing` walks the records in Review order with a stack of ancestors by depth. A match marks each hidden ancestor as a context entry. Then the listing emits the records in the order of the Overview State.
- `list_overlay.Query.parse` now owns the query trim and the needle split. The fuzzy lists and the Comment Overview share it.
- `comment_overview.Change` names each Overview State change. `Published.changeOverview` applies it to a copy of the Overview State and publishes the copy only after the listing build succeeds. So an allocation failure keeps the previous listing and query.
- The query keeps whole UTF-8 scalars up to 256 bytes. Text that does not fit is dropped without a status message, because M29 adds no ActionError for it. Text that is not valid UTF-8 is ignored.
- Escape or `ctrl-c` that cannot restore the saved query, because of an allocation failure, keeps the query input open and reports `out_of_memory`.
- A Count before `/`, `u`, `d`, `a`, or `o` ends there. While the query input is open, digits insert as text.
- A lost Authenticated Account (an Unauthorized result) marks the Overview Index stale through `forgetAuthenticatedAccount`. So mine only keeps no Comment after the next rebuild.
- `comment_overview.Frame.state` is a `*const State` that borrows the Overview State from `Published`. vaxis cells borrow their text until render. A by-value copy of the query buffer on a stack left dangling cells. Now the type rejects a by-value copy at compile time.
- The order chip stays muted in both orders, because it is not a filter. Its text names the order.
- At 80 columns, the filter row is 50 cells wide. The chips then drop from the end, so the order chip shows only from about 85 columns. This follows the spec rule for a narrow row.
- After the merge with PR #16, review findings M29-2 and M29-5 touched the query input. Ticket 06 records the fixes.
- The second review fix round added M29-9 tests for Overview Index invalidation. Ticket 06 records them.

## Completion

Changed paths: `src/tui/comment_overview.zig`, `src/tui/presentation.zig`, `src/tui/action.zig`, `src/tui/keymap.zig`, `src/tui/list_overlay.zig`, `src/tui/render.zig`, `src/tui/app.zig`.

Summary: `/` opens the query input in the Comment Overview. `u`, `d`, and `a` toggle unresolved only, Drafts only, and mine only. `o` switches between Review order and newest first. `buildListing` applies the filters with AND, shows the ancestors of a matching entry as context entries, and counts only the matches. The filter row shows the query, the cursor cell, and the chips. The status shows `/ filter`, and the Command Palette lists the five new entries.

Tests:

- "M29 overview the query matches the author, the body, and the path and keeps the order" in `src/tui/comment_overview.zig`.
- "M29 overview each toggle keeps only matching items and the toggles combine with AND" in `src/tui/comment_overview.zig`. It also proves the Draft-root Thread and the resolved Thread for unresolved only.
- "M29 overview mine only keeps every Draft and only the Comments of the Authenticated Account" in `src/tui/comment_overview.zig`.
- "M29 overview a matching Reply keeps its ancestors as context entries outside the Title count" in `src/tui/comment_overview.zig`.
- "M29 overview newest first puts Draft Threads first, sorts Comment Threads by their newest CommentId, and keeps Replies under their parents" in `src/tui/comment_overview.zig`.
- "M29 overview the query input edits the query and a Count never reaches it" in `src/tui/presentation.zig`.
- "M29 overview the query keeps whole scalars up to 256 bytes" in `src/tui/presentation.zig`.
- "M29 overview a filter change that hides the selected entry selects the next shown entry" in `src/tui/presentation.zig`.
- "M29 overview an allocation failure during a query edit keeps the previous listing and query" in `src/tui/presentation.zig`.
- "M29 overview u, d, a, and o change the listing, and g d and g o keep the query, the toggles, and the order" in `src/tui/presentation.zig`.
- "M29 overview a lost Authenticated Account keeps no Comment in mine only" in `src/tui/presentation.zig`.
- "M29 overview the filter row shows the query, the cursor cell, and the active chips" in `src/tui/render.zig`.
- "M29 overview /, u, d, a, and o filter and order only in the Comment Overview and remain configurable" in `src/tui/keymap.zig`.
- "M29 overview the Command Palette lists the filter and order entries only from the Comment Overview" in `src/tui/list_overlay.zig`.

Mutation checks: removing the Count reset in `openOverviewQuery` or the stale mark in `forgetAuthenticatedAccount` fails a test.

Checks:

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-comment-overview`: 63/63 pass.
- `zig build test --summary all`: 1437/1437 pass (baseline 1423).
- `python3 tools/check_agent_docs.py`: pass.

Review result: the runner reviewed the diff and reran every check. The runner replaced the per-paint query copy with the borrowed `*const State` above. This fix is at the type level, because a by-value `State` in the Frame no longer compiles.

Commit: see the `tui: filter and order the Comment Overview` commit.
