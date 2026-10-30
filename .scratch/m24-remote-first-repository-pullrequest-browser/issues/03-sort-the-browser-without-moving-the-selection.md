# 03: Sort the Browser without moving the Selection

Status: resolved
Blocked by: 02
Spec: [M24 spec](../SPEC.md)

## What to build

A reviewer presses `s` in the Browser.
The Browser switches between the updated-time Sort and the name-and-id Sort.
The cursor stays on the same Repository or PullRequest.

## Scope

- Add `Sort` handling to `browser.entries` in `src/tui/browser.zig`, as the "Sort" section of the spec describes.
- Add the Action `cycle_browser_sort` with the default key `s` in the three Browser contexts.
- Keep the Sort in `Presentation.browser`, so it survives Session replacement and `close_browser`.
- Move the scroll only when the selected row leaves the viewport.

## Acceptance criteria

- [x] The updated-time Sort orders Repositories by update time, newest first, then by slug.
- [x] The updated-time Sort orders PullRequests by update time, newest first, then by PullRequestId, highest first.
- [x] The name Sort orders Repositories by name without ASCII case, then by slug.
- [x] The name Sort orders PullRequests by PullRequestId, highest first.
- [x] A `null` time sorts last.
- [x] Each Sort change keeps the Selection on the same Repository or PullRequest.
- [x] A Sort change keeps the scroll when the selected row stays in the viewport.
- [x] The Sort survives a Session replacement and a return with `b`.
- [x] `s` resolves to `cycle_browser_sort` only in the Browser contexts, and still resolves to `toggle_layout` in the DiffPane.

## Tests that prove it

- `M24 browser` Sort tests in `src/tui/browser.zig` and `src/tui/presentation.zig`.
- Keymap tests in `src/tui/keymap.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test --summary all`

## Completion

This commit implements the ticket.

### Change summary

- `src/tui/action.zig` adds the Action `cycle_browser_sort`.
- `src/tui/keymap.zig` binds `s` to `cycle_browser_sort`, and the `browser` arm of `supportsContext` supports it.
  `browser_repository` and `browser_pull_request` inherit it from `browser`.
  The DiffPane and Sidebar contexts do not support it, so `s` still resolves to `toggle_layout` there.
- `Browser.cycleSort` in `src/tui/browser.zig` switches between `.updated` and `.name` and calls `rebuild`.
  On an allocation failure, the previous Sort and Entries stay.
- `Presentation.applyBrowserAction` calls `Browser.cycleSort`, and an allocation failure shows `out_of_memory`.
- The Browser status shows the hint `s sort` in the new `StatusSlot.sort`.
- The help Overlay reads the Keymap, so it lists "sort by update time / name" with no other change.

### Verification of the existing code

- `RepositoryOrder` and `PullRequestOrder` already match the "Sort" section of the spec.
  This commit does not change them.
- `Browser.rebuild` already follows the Selection, and `keepCursorVisible` already moves the scroll only when the cursor leaves the viewport.
  This commit does not change them.
- Two mutations prove that the new tests see the behavior.
  A case-sensitive name order fails two tests.
  A scroll reset in `rebuild` fails the scroll test.

### Tests

- `src/tui/browser.zig`: "M24 browser the name Sort orders Repositories by name without ASCII case, then slug, and PullRequests by id", "M24 browser a Sort change keeps the selected Repository and moves the scroll only when its row leaves the viewport", and "M24 browser a Sort change keeps the selected PullRequest".
- The existing test "M24 browser entries order Repositories and PullRequests by update time, newest first, with null last" proves the updated-time Sort.
- `src/tui/presentation.zig`: "M24 browser s switches the Sort, keeps the Selection, and survives a return and a Session replacement".
- `src/tui/keymap.zig`: "M24 browser s cycles the Browser Sort only in the Browser contexts".
- `src/tui/app.zig`: the test "M24 browser the status shows the Browser hints, the Candidate Session load, and the Browser texts" now also checks the `s` hint.

### Checks

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-browser`: pass, 49 tests in two test binaries. The baseline was 44.
- `zig build test --summary all`: "24/24 steps succeeded; 1422/1422 tests passed". The baseline was 1417.
- `python3 tools/check_box_glyphs.py` and `python3 tools/check_xdg_reads.py`: pass.
- `python3 tools/check_agent_docs.py`: pass.

### Review

- I read the full diff.
- I found no leak, no new exhaustive switch gap, and no AGENTS.md rule violation.
- The Command Palette does not open from the Browser in M24, so it has no entry for `cycle_browser_sort`.
  `close_browser` and `open_browser_entry` have no entry either.

### Defaults chosen

- The help text is "sort by update time / name".
- The Browser status shows `s sort`, because every other Browser Action has a status hint.
  The status does not name the active Sort, because the spec does not ask for it.
- In the review help Overlay, the `s` row for `cycle_browser_sort` shows as available.
  This matches the `close_browser` and `open_browser_entry` rows from ticket 02.

