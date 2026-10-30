# 02: Open an Overview Entry at its ReviewCard

Status: ready-for-agent
Blocked by: 01
Spec: [M29 spec](../SPEC.md)

## What to build

A reviewer selects an Overview Entry and presses Enter.
The DiffPane shows with the cursor on the header row of that entry's ReviewCard.
The jump works for every CommentScope, also when the ReviewCard hides behind a disclosure.
The Comment Overview keeps its Overview State, so `g o` returns to the same place.
A stale jump never moves a later view.

## Scope

- Add the Action `open_overview_entry` with Enter in the `comment_overview` context.
- Add `DisclosureBuild.Kind.overview_destination`, `overview_destination_id`, and `Published.overview_destination_generation` to `src/tui/presentation.zig`.
- Compute the isolation, Selected Version, and required disclosures as the spec describes.
  Reuse `disclosureChain` and `sourceFoldDisclosure`.
- Find the destination row by the entry's `review_card.Owner` and `Part.header`.
- Publish the Buffer, `main_pane = .diff_pane`, the centered cursor, and `revealActiveFile` in one infallible step.
- Increment the generation for a second Enter, `show_diff_pane`, and `show_comment_overview`.
- Add `overview_entry_unavailable` with its `actionErrorText` text.
- Refuse `open_overview_entry` with `no_review_item` when no entry is selected.
- A click on the selected entry runs `open_overview_entry`.
- Add the `↵ open` status hint.
- Add the Command Palette entry "Open in DiffPane" and the help text "open entry in DiffPane".

## Acceptance criteria

- [ ] "M29 overview Enter puts the ReviewCard header under the cursor for every CommentScope" passes for Review-level, File-level, new-side inline, and old-side inline items.
- [ ] Enter works for a Reply, a Draft, and a Draft Reply to a Comment.
- [ ] Enter on an item of a collapsed resolved Thread opens only that Thread's disclosure.
- [ ] Enter on an outdated item opens its outdated File or Review section.
- [ ] Enter on an old-side inline item sets Selected Version to old.
- [ ] Enter on an item in another File moves an active isolation to that File.
- [ ] Enter on a Review-level item ends File isolation.
- [ ] A collapsed ReviewCard body stays collapsed after the jump.
- [ ] After the jump, `g o` shows the same selection and scroll.
- [ ] A second Enter supersedes the first pending destination.
- [ ] `g d` during a pending destination keeps the DiffPane cursor where it was.
- [ ] A Session replacement during a pending destination destroys the job and changes nothing.
- [ ] A changed geometry during a pending destination retries the build.
- [ ] A missing destination row keeps the Comment Overview and reports `overview_entry_unavailable`.
- [ ] A failed build keeps the Comment Overview and reports `buffer_build_failed`.
- [ ] Enter on an empty listing reports `no_review_item`.
- [ ] A click on the selected entry opens it.
- [ ] The Command Palette lists "Open in DiffPane" from the Comment Overview.

## Tests that prove it

- Presentation tests in `src/tui/presentation.zig`, including the allocation-failure cases for `overview_destination` in the `checkAllAllocationFailures` list of disclosure kinds.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`
