# 02: Open an Overview Entry at its ReviewCard

Status: resolved
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

- [x] "M29 overview Enter puts the ReviewCard header under the cursor for every CommentScope" passes for Review-level, File-level, new-side inline, and old-side inline items.
- [x] Enter works for a Reply, a Draft, and a Draft Reply to a Comment.
- [x] Enter on an item of a collapsed resolved Thread opens only that Thread's disclosure.
- [x] Enter on an outdated item opens its outdated File or Review section.
- [x] Enter on an old-side inline item sets Selected Version to old.
- [x] Enter on an item in another File moves an active isolation to that File.
- [x] Enter on a Review-level item ends File isolation.
- [x] A collapsed ReviewCard body stays collapsed after the jump.
- [x] After the jump, `g o` shows the same selection and scroll.
- [x] A second Enter supersedes the first pending destination.
- [x] `g d` during a pending destination keeps the DiffPane cursor where it was.
- [x] A Session replacement during a pending destination destroys the job and changes nothing.
- [x] A changed geometry during a pending destination retries the build.
- [x] A missing destination row keeps the Comment Overview and reports `overview_entry_unavailable`.
- [x] A failed build keeps the Comment Overview and reports `buffer_build_failed`.
- [x] Enter on an empty listing reports `no_review_item`.
- [x] A click on the selected entry opens it.
- [x] The Command Palette lists "Open in DiffPane" from the Comment Overview.

## Tests that prove it

- Presentation tests in `src/tui/presentation.zig`, including the allocation-failure cases for `overview_destination` in the `checkAllAllocationFailures` list of disclosure kinds.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`

## Comments

- `queueOverviewDestination` does not call `disclosureChain`. `disclosureChain` reads the disclosure rows of the current Buffer. So it misses the outdated section of a File that the current isolation hides. The new `reviewCardDestination` computes the isolation, the Selected Version, the File, and the outdated keys from the Diff. `openReviewSearchOccurrence` now calls the same function for a ReviewBody occurrence, and its behavior does not change.
- The required disclosures are the resolved Thread of the root, the outdated File or Review section, and the Fold over the anchored Line. The Fold comes from `sourceFoldDisclosure` in the worker, through the same code path as a source `review_destination`. The opposite version section is not necessary, because the jump sets Selected Version to the side of the Anchor.
- The jump never adds a `review_card` key, so a collapsed ReviewCard body stays collapsed.
- `reviewCardHeaderRow` reads the Buffer row and not the RowOwner. The header of an expanded resolved Thread root has the disclosure identity as its RowOwner.
- The job carries `overview_owner`. A retry looks up that Owner in the Overview Index again, and not the current selection. A missing record reports `overview_entry_unavailable`.
- `show_diff_pane` and `show_comment_overview` call `cancelOverviewDestination`. Ticket 04 can route the File Finder choice through `showDiffPane`, or call `cancelOverviewDestination` itself.
- `open_overview_entry` is unavailable without a selection, as edit, re-anchor, and delete are without a ReviewCard. So the help test "local help projection marks remote-only commands unavailable" now counts 12 unavailable rows.
- `DisclosureBuild.Kind.rebuildsContent` replaces two copies of the content-build kind list with one exhaustive switch.
- The failed-build criterion is proved by the `overview_destination` arm of "M21 kernel Frame worker allocation failures preserve the graph and complete Frame". That test is outside `zig build test-comment-overview`, but `zig build test` runs it.
- The missing-row test replaces `overview_owner` on the issued job. No fixture puts an index record outside the DiffPane Buffer, because the index comes from the same Buffer build.
- After the merge with PR #16, review findings M29-3 and M29-4 touched this ticket's Enter behavior. Ticket 06 records the fixes.

## Completion

Commit: see the `tui: open an Overview Entry at its ReviewCard` commit. Changed paths: `src/tui/action.zig`, `src/tui/keymap.zig`, `src/tui/list_overlay.zig`, `src/tui/app.zig`, `src/tui/render.zig`, `src/tui/presentation.zig`.

Summary: Enter in the Comment Overview queues one `overview_destination` DisclosureBuild. The build opens the disclosures that hide the ReviewCard and finds its header row. Acceptance publishes the Buffer, shows the DiffPane, centers the cursor on the header row, and reveals the active File. `Published.overview_destination_generation` lets only the latest destination publish. A click on the selected entry, the Command Palette entry "Open in DiffPane", and the `↵ open` status hint reach the same Action.

Tests:

- "M29 overview Enter puts the ReviewCard header under the cursor for every CommentScope": Review-level, File-level, new-side, old-side, Reply, Draft Reply to a Comment, Review-level Draft, another File, and a folded Line.
- "M29 overview Enter opens only the disclosure that hides the ReviewCard": resolved Thread root and Reply, outdated File section, outdated Review section, and Fold.
- "M29 overview a collapsed ReviewCard body stays collapsed after the jump".
- "M29 overview Enter moves File isolation to the item's File and ends it for a Review-level item".
- "M29 overview g o after the jump shows the same selection and scroll".
- "M29 overview a second Enter supersedes the first pending destination".
- "M29 overview g d and g o during a pending destination keep the DiffPane cursor where it was".
- "M29 overview a Session replacement during a pending destination destroys the job and changes nothing".
- "M29 overview a changed geometry during a pending destination retries the build".
- "M29 overview a missing destination row keeps the Comment Overview and reports overview_entry_unavailable".
- "M21 kernel Frame worker allocation failures preserve the graph and complete Frame" with `overview_destination`.
- "M29 overview Enter on an empty listing reports no_review_item".
- "M29 overview a click on the selected entry opens it".
- "M29 overview Enter opens the selected entry only in the Comment Overview and remains configurable" in `src/tui/keymap.zig`.
- "M29 overview the Command Palette lists Open in DiffPane only from the Comment Overview" in `src/tui/list_overlay.zig`.

Mutation checks: removing the resolved Thread key, the generation check, the cancel in `showDiffPane`, the outdated keys, or the Fold source each fails at least one of these tests.

Checks:

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-comment-overview`: 49/49 pass.
- `zig build test --summary all`: 1423/1423 pass (baseline 1409).
- `python3 tools/check_agent_docs.py`: pass.

Review result: the runner read the `presentation.zig` diff and reran every check. The runner found no blocking issue.
