# 05: Route Review-level Review Search results through the Comment Overview

Status: ready-for-agent
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

- [ ] A Review-level Comment result shows the Comment Overview with the Comment selected and in view.
- [ ] A Review-level Draft result shows the Comment Overview with the Draft selected.
- [ ] The route clears a query, a toggle, or a File Tree Filter only when it hides the item.
- [ ] The route keeps the order.
- [ ] The route reports `overview_filters_cleared` only when it clears a filter.
- [ ] A File-level, inline, or source result still lands in the DiffPane through `review_destination`.
- [ ] A `review_destination` opened from the Comment Overview shows the DiffPane when it publishes.
- [ ] An occurrence from an earlier Session Epoch does nothing.
- [ ] `g f` opens Review Search from the Comment Overview.

## Tests that prove it

- Presentation tests in `src/tui/presentation.zig`, next to the existing `M21 authored` Review Search destination tests.
- Keymap tests in `src/tui/keymap.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`
