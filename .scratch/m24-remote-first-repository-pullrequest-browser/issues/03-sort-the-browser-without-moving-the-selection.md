# 03: Sort the Browser without moving the Selection

Status: ready-for-agent
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

- [ ] The updated-time Sort orders Repositories by update time, newest first, then by slug.
- [ ] The updated-time Sort orders PullRequests by update time, newest first, then by PullRequestId, highest first.
- [ ] The name Sort orders Repositories by name without ASCII case, then by slug.
- [ ] The name Sort orders PullRequests by PullRequestId, highest first.
- [ ] A `null` time sorts last.
- [ ] Each Sort change keeps the Selection on the same Repository or PullRequest.
- [ ] A Sort change keeps the scroll when the selected row stays in the viewport.
- [ ] The Sort survives a Session replacement and a return with `b`.
- [ ] `s` resolves to `cycle_browser_sort` only in the Browser contexts, and still resolves to `toggle_layout` in the DiffPane.

## Tests that prove it

- `M24 browser` Sort tests in `src/tui/browser.zig` and `src/tui/presentation.zig`.
- Keymap tests in `src/tui/keymap.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test --summary all`
