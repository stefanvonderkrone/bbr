# 02: Open the Browser from a review Session

Status: resolved
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

- [x] The first `b` expands the Session's Repository and focuses its PullRequest when its row appears.
- [x] A cursor Motion before the row appears clears the pending focus.
- [x] A later `b` starts no request and shows the same expansion, Selection, scroll, and summaries.
- [x] A Session replacement and a failed replacement keep the Browser state unchanged.
- [x] Escape and `b` in the Browser return to the published Session.
- [x] Escape with no published Session is refused with `no_review_open`.
- [x] `b` in a LocalReview is refused with `local_review_no_browser`, and `b` in the demo is refused with `action_refused`.
- [x] The Repository list shows its loading, empty, and failure message entries.
- [x] A Repository list failure with rows keeps the rows and shows `browser_repositories_failed`.
- [x] A Repository list success removes a Repository that it no longer contains.
- [x] Expanding a Repository queues one load, and expanding it again starts no request.
- [x] Three expansions issue two commands, and the third starts after a completion.
- [x] Collapsing a waiting Repository removes it from the FIFO.
- [x] A stale Repository list completion and a stale PullRequest completion change nothing and free their payloads.
- [x] `refresh` reloads the Repository list and every expanded Repository, and supersedes the loads in flight.
- [x] One failed Repository keeps the PullRequests of every other Repository.
- [x] A `forbidden` or `not_found` failure drops the previous list, and other failures keep it.
- [x] A `rate_limited` failure empties the FIFO and shows `browser_rate_limited`.
- [x] A refreshed PullRequest list removes a closed PullRequest.
- [x] When the selected PullRequest goes away, the cursor moves to its Repository row.
- [x] A Repository entry shows its name, slug, date, and count, or `?` before its load.
- [x] A PullRequest entry shows id, title, author, date, branches, and both counts, and truncates its title first.
- [x] Enter on a PullRequest entry starts the Candidate Session, and publication shows the review surface.
- [x] A failed replacement from the Browser keeps the Browser visible.
- [x] A click selects an entry, a second click opens it, and a click on a message entry does nothing.
- [x] The Browser Pane has rounded corners, the Workspace Title, and a declared scroll bar.
- [x] Each new Action resolves only in its contexts, and a `[keymap]` override can rebind and unbind it.
- [x] The Command Palette lists "Open Browser" from the Panes.

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

## Completion

This commit implements the ticket.

### Change summary

- `src/tui/browser.zig` is new. It holds the Browser model, `Start`, `Selection`, `Entry`, `Message`, `Sort`, `PullRequestLoad`, and the pure `entries` projection.
  It also owns `PullRequestSummaries`, `RepositorySummaries`, and `formatDate`.
  It imports neither vaxis nor `theme.zig`.
- `Presentation.browser` holds the Browser outside `Published`, and `Presentation.surface` is `.review` or `.browser`.
  The new input `start_browser` takes a Browser Start with a Workspace, an optional Repository, and an optional PullRequestId.
  The first `open_browser` builds that Browser Start from the published Session.
- The commands `list_browser_repositories` and `list_browser_pull_requests` carry a WorkId.
  Their completions are `browser_repositories_loaded` and `browser_pull_requests_loaded`.
  Each command has a `deinit` arm and a `launchFailed` arm.
- At most two `list_browser_pull_requests` commands are queued or issued at one time.
  The other loads wait in a FIFO of tickets.
- `presentation_adapter.listBrowserRepositories` and `presentation_adapter.listBrowserPullRequests` run the loads, and `app.zig` launches them on workers.
- The Actions `open_browser`, `close_browser`, and `open_browser_entry` and the Interaction Contexts `browser`, `browser_repository`, and `browser_pull_request` are new.
  `b` opens and closes the Browser, Escape closes it, and Enter opens the entry under the cursor.
- The Command Palette lists "Open Browser" from the Panes.
- `layouts.browser`, `frame.BrowserTarget`, `HitTarget.browser_entry`, and `render.drawBrowser` paint and target the Browser.
- `app.zig` paints the Browser when `Projection.browser` is set and shows the Browser status, including "Loading PR #N…".
- The `ActionError` values `local_review_no_browser`, `no_review_open`, `browser_rate_limited`, and `browser_repositories_failed` have their texts.

### Defaults chosen

- A PullRequest load is a struct of the last settled list and an optional request, not one union.
  A waiting Repository then keeps its earlier list, and a `rate_limited` failure returns it to that list exactly.
- A `Selection` owns a fixed-buffer `Name`, so it stays valid after the Repository list is replaced.
- A list failure stores a `browser.Failure`. It is the `ApiError` set plus `OutOfMemory`, `ConnectionFailed`, and `WorkerLaunchFailed`.
- The bound of two counts queued and issued commands. A `refresh` and a shutdown remove the queued commands and release their requests.
- Only a replacement with the `picker` cause switches the surface to the review. A refresh or a Reconciliation keeps the Browser visible.
- The `loading_repositories` and `repositories_failed` messages follow the Repository rows until a Repository list succeeds.
- A Repository that left the FIFO after `rate_limited` shows no message entry and a `?` count.
- A click on the entry under the cursor opens it, as the spec says. It needs no double-click time.
- The help in the Browser greys the Actions that the Browser context does not support.
- The test "local help projection marks remote-only commands unavailable" now counts 12 unavailable commands, because `open_browser` is unavailable in a LocalReview.

### Checks

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-browser`: pass, 44 tests in two test binaries.
- `zig build test --summary all`: "24/24 steps succeeded; 1417/1417 tests passed". The baseline was 1387.
- `python3 tools/check_box_glyphs.py` and `python3 tools/check_xdg_reads.py`: pass.
- `python3 tools/check_agent_docs.py`: pass.

### Review

- A separate review agent read the full diff.
- It found a stuck load after a refresh removed a queued command, and new loads after shutdown.
  This commit fixes both, and the tests "M24 browser a refresh replaces queued loads and a collapsed queued Repository loads again" and "M24 browser shutdown starts no Browser load and waits for the loads in flight" prove the fixes.
- It found no leak, no double free, and no AGENTS.md rule violation.
- Ticket 06 adds the M24 rows to the AGENTS.md rule table. The tests that those rows name exist now.
