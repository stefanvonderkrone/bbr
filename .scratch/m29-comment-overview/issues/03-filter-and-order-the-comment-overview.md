# 03: Filter and order the Comment Overview

Status: ready-for-agent
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

- [ ] The query matches the author, the body, and the path, and a blank query matches every item.
- [ ] The query filters and does not change the order.
- [ ] Each toggle keeps only matching items, and the toggles combine with AND.
- [ ] Unresolved only keeps a Draft-root Thread and drops a resolved Comment Thread.
- [ ] Mine only keeps every Draft in a LocalReview and in a RemoteReview.
- [ ] Mine only keeps a Comment only when its `author_uuid` equals the Authenticated Account.
- [ ] Without a known Authenticated Account, mine only keeps no Comment.
- [ ] A matching Reply shows its non-matching ancestors as dim context entries.
- [ ] The Title counts exclude context entries.
- [ ] Newest first puts a Draft Thread before Comment Threads and sorts Comment Threads by their newest CommentId.
- [ ] Newest first keeps each Reply under its parent.
- [ ] The query input inserts text and deletes with Backspace, `ctrl-w`, and `ctrl-u`.
- [ ] Enter keeps the edited query, and Escape restores the saved query.
- [ ] A filter change that hides the selected entry selects the next shown entry.
- [ ] An allocation failure during a query edit keeps the previous listing and query.
- [ ] `g d` and `g o` keep the query, the toggles, and the order.
- [ ] The filter row shows the active chips in the active style and the inactive chips muted.
- [ ] The default Keymap passes `validateBindings` with the new bindings.
- [ ] A `[keymap]` override can rebind and unbind each new Action.
- [ ] The Command Palette lists the five entries from the Comment Overview.

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
