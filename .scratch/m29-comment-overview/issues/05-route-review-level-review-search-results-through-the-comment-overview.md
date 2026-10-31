# 05: Route Review-level Review Search results through the Comment Overview

Status: resolved
Blocked by: 02, 04
Spec: [M29 spec](../SPEC.md)

## What to build

A reviewer opens a Review Search result for a Review-level Comment or Draft.
Review Search closes, and the Comment Overview shows with that item selected.
If an Overview filter hides the item, Presentation clears only that filter and says so in the status.
Every other Review Search result keeps the M21 route to the DiffPane.
Review Search also opens from the Comment Overview.

## Scope

- Change `openReviewSearchOccurrence` in `src/tui/presentation.zig` for a ReviewBody occurrence whose current scope is `.review`.
  Close Review Search, clear the hiding filters, show the Comment Overview, and select the Owner.
- Set `main_pane = .diff_pane` when a `review_destination` publishes.
- Support `open_review_search` in the `comment_overview` context.
- Add `overview_filters_cleared` with its `actionErrorText` text.

## Acceptance criteria

- [x] A Review-level Comment result shows the Comment Overview with the Comment selected and in view.
- [x] A Review-level Draft result shows the Comment Overview with the Draft selected.
- [x] The route clears a query, a toggle, or a File Tree Filter only when it hides the item.
- [x] The route keeps the order.
- [x] The route reports `overview_filters_cleared` only when it clears a filter.
- [x] A File-level, inline, or source result still lands in the DiffPane through `review_destination`.
- [x] A `review_destination` opened from the Comment Overview shows the DiffPane when it publishes.
- [x] An occurrence from an earlier Session Epoch does nothing.
- [x] `g f` opens Review Search from the Comment Overview.

## Tests that prove it

- Presentation tests in `src/tui/presentation.zig`, next to the existing `M21 authored` Review Search destination tests.
- Keymap tests in `src/tui/keymap.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`

## Comments

- `comment_overview.Filter` names the five filters, and `comment_overview.Filters` is an `EnumSet` of them. The order is not a filter. `keeps` and the new `hidingFilters` share one exhaustive `passes` switch, so the listing and the route can never disagree on a filter.
- `hidingFilters` returns every active filter that the record fails. The filters combine with AND, so a State without exactly these filters lists the record as a match. `State.clear` clears them.
- The route asks for a match, not only a visible entry. A Review-level item can show only as a context entry, for example a root whose Reply matches. The route then also clears the filters that hide it, so the item becomes a match. This follows the runner note to decide by the match.
- `showCommentOverview` takes an optional Owner to reveal. The Action passes null, and the route passes the Owner. Both use one show path: stage the index, clear the hiding filters, stage the File Tree, build the listing, and publish in one infallible step. With an Owner, the path also runs while the Comment Overview already shows. A cleared File Tree Filter puts the File Tree cursor on the root entry.
- `Published.rebuildOverview` is now `stageOverviewIndex` and `publishOverview`. The route needs the staged index to find the record before it stages the File Tree.
- The route shows the Comment Overview first and closes Review Search only after success. So an allocation failure keeps Review Search open and the previous Presentation Frame. The spec lists the close as step 1. The visible result after success is the same.
- A Review-level item that the index does not list, such as a Draft in the `submitting` state, reports `overview_entry_unavailable` and keeps Review Search open.
- `DisclosureBuild.Kind.publishedPane` names the Main Pane that each job kind publishes, with an exhaustive switch. The worker builds the File Tree for that pane, and `acceptViewBuild` sets `main_pane` from it. It replaces the `overview_destination` special case. `DisclosureBuild.main_pane` still records the Main Pane at create, so `treeCurrent` compares like with like and a `review_destination` from the Comment Overview publishes on its first completion.
- A published `review_destination` also cancels a pending Overview destination, because it is a later view.
- Changed earlier tests, because the spec changes the behavior:
  - "M21 authored scope opening resolves Review File Reply and outdated locations" in `src/tui/presentation.zig`: the Review-level case now expects the Comment Overview with the Comment selected and an unchanged DiffPane.
  - "M23 emoji search ...", "M23 tables search ...", "M23 links search ...", and "M23 inline joined search ..." in `src/tui/presentation.zig`, and "M21 authored destination launch failure and closed sink preserve the Overlay and Frame" in `src/tui/presentation_runtime.zig`: the fixture Draft or Comment is now File-level, so these tests still prove the DiffPane route.
  - "M29 overview g o and g d resolve in every Pane context and remain configurable" in `src/tui/keymap.zig` no longer expects `g f` to do nothing in the Comment Overview.
  - "M29 overview the Command Palette lists the Main Pane Actions from every Pane" in `src/tui/list_overlay.zig` now expects "Search Review" from the DiffPane and the Comment Overview.

## Completion

Changed paths: `src/tui/comment_overview.zig`, `src/tui/presentation.zig`, `src/tui/presentation_runtime.zig`, `src/tui/keymap.zig`, `src/tui/list_overlay.zig`, `src/tui/app.zig`.

Summary: a Review Search result for a Review-level Comment or Draft now shows the Comment Overview with the item selected and in view. The route clears only the filters that hide the item and keeps the order. It reports `overview_filters_cleared` only when it clears a filter. Other results keep the M21 route, and a `review_destination` publishes the DiffPane without the root entry. `g f` opens Review Search from the Comment Overview.

Tests:

- "M29 overview a Review-level Review Search result shows the Comment Overview with the item selected": a Comment below the first viewport and a Review-level Draft, no Buffer build, and an unchanged DiffPane.
- "M29 overview the Review Search route clears only the filters that hide the item and keeps the order": query, File Tree Filter, unresolved only, Drafts only, mine only, newest first, the root entry cursor, and the status.
- "M29 overview a File-level or inline Review Search result from the Comment Overview shows the DiffPane once".
- "M29 overview a source Review Search result from the Comment Overview shows the DiffPane once".
- "M29 overview a Review-level result from an earlier Session Epoch does nothing".
- "M29 overview g f opens Review Search from the Comment Overview and remains configurable" in `src/tui/keymap.zig`.
- "M29 overview the status shows the Comment Overview hints and the listing position" in `src/tui/app.zig` checks the `overview_filters_cleared` text.

Mutation checks: each of these changes fails at least one test. Skip `State.clear`, clear every active filter, keep Review Search open after the route, skip the `main_pane` publication in `acceptViewBuild`, build the `review_destination` File Tree with the root entry, or record the published pane at create (the job then retries).

Checks:

- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-comment-overview`: 77/77 pass.
- `zig build test --summary all`: 1451/1451 pass (baseline 1445).
- `python3 tools/check_agent_docs.py`: pass.

Review result: the runner reviewed the `presentation.zig` diff and reran every check. The runner found no blocking issue. Ticket 06 adds the allocation-failure test for this route.

Commit: see the `tui: route Review-level search results to the Overview` commit.
