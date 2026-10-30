# 02: Open the Browser from a review Session

Status: ready-for-agent
Blocked by: 01
Spec: [M24 spec](../SPEC.md)

## What to build

A reviewer presses `b` in a review Session.
The Browser opens with the Session's Repository expanded and its PullRequest focused.
The Browser lists every Repository of the Workspace.
Expanding a Repository loads its open PullRequests on demand.
Enter on a PullRequest entry opens its review Session.
`b` again shows the Browser exactly as the reviewer left it.

This slice uses the updated-time Sort only.
Ticket 03 adds `cycle_browser_sort`.
This slice has no Summary Cache and no startup change.

## Scope

- Add `src/tui/browser.zig` with the Browser model, `Selection`, `Entry`, `Message`, `PullRequestLoad`, and `entries`.
- Add `Presentation.browser`, `Presentation.surface`, `Projection.browser`, and `start_browser` to `src/tui/presentation.zig`.
- Add the commands `list_browser_repositories` and `list_browser_pull_requests` with their completions, `deinit` arms, and `launchFailed` arms.
- Add the worker functions to `src/tui/presentation_adapter.zig` and their launch in `src/tui/app.zig`.
- Add the FIFO and the bound of two outstanding PullRequest list commands.
- Add the Actions `open_browser`, `close_browser`, and `open_browser_entry`.
  Add the Interaction Contexts `browser`, `browser_repository`, and `browser_pull_request`.
- Add the default keys and `supportsContext` arms in `src/tui/keymap.zig`.
- Add the "Open Browser" Command Palette entry in `src/tui/list_overlay.zig`.
- Add `layouts.browser`, `HitTarget.browser_entry`, and `render.drawBrowser`.
- Add the `ActionError` values `local_review_no_browser`, `no_review_open`, `browser_rate_limited`, and `browser_repositories_failed` with their texts.
- Paint the Browser in `app.zig` when `Projection.browser` is set.

## Acceptance criteria

- [ ] The first `b` expands the Session's Repository and focuses its PullRequest when its row appears.
- [ ] A cursor Motion before the row appears clears the pending focus.
- [ ] A later `b` starts no request and shows the same expansion, Selection, scroll, and summaries.
- [ ] A Session replacement and a failed replacement keep the Browser state unchanged.
- [ ] Escape and `b` in the Browser return to the published Session.
- [ ] Escape with no published Session is refused with `no_review_open`.
- [ ] `b` in a LocalReview is refused with `local_review_no_browser`, and `b` in the demo is refused with `action_refused`.
- [ ] The Repository list shows its loading, empty, and failure message entries.
- [ ] A Repository list failure with rows keeps the rows and shows `browser_repositories_failed`.
- [ ] A Repository list success removes a Repository that it no longer contains.
- [ ] Expanding a Repository queues one load, and expanding it again starts no request.
- [ ] Three expansions issue two commands, and the third starts after a completion.
- [ ] Collapsing a waiting Repository removes it from the FIFO.
- [ ] A stale Repository list completion and a stale PullRequest completion change nothing and free their payloads.
- [ ] `refresh` reloads the Repository list and every expanded Repository, and supersedes the loads in flight.
- [ ] One failed Repository keeps the PullRequests of every other Repository.
- [ ] A `forbidden` or `not_found` failure drops the previous list, and other failures keep it.
- [ ] A `rate_limited` failure empties the FIFO and shows `browser_rate_limited`.
- [ ] A refreshed PullRequest list removes a closed PullRequest.
- [ ] When the selected PullRequest goes away, the cursor moves to its Repository row.
- [ ] A Repository entry shows its name, slug, date, and count, or `?` before its load.
- [ ] A PullRequest entry shows id, title, author, date, branches, and both counts, and truncates its title first.
- [ ] Enter on a PullRequest entry starts the Candidate Session, and publication shows the review surface.
- [ ] A failed replacement from the Browser keeps the Browser visible.
- [ ] A click selects an entry, a second click opens it, and a click on a message entry does nothing.
- [ ] The Browser Pane has rounded corners, the Workspace Title, and a declared scroll bar.
- [ ] Each new Action resolves only in its contexts, and a `[keymap]` override can rebind and unbind it.
- [ ] The Command Palette lists "Open Browser" from the Panes.

## Tests that prove it

- `M24 browser` tests in `src/tui/presentation.zig`, including:
  "M24 browser Session replacement and return keep the Browser state",
  "M24 browser a stale completion changes nothing and frees its payload", and
  "M24 browser keeps at most two PullRequest list requests outstanding".
- The test "every OwnedCommand launch failure keeps its correlation and frees the command", extended for the new commands.
- `M24 browser` tests for `entries` in `src/tui/browser.zig`.
- Render tests in `src/tui/render.zig`, including "M24 browser the Browser Pane has rounded corners and the Workspace Title".
- Hit-test tests in `src/tui/frame.zig` and the layout test "every layout places each of its Slots" in `src/tui/layouts.zig`.
- Keymap and Command Palette tests in `src/tui/keymap.zig` and `src/tui/list_overlay.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test --summary all`
