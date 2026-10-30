# 05: Detect the startup target inside the TUI

Status: resolved
Blocked by: 02
Spec: [M24 spec](../SPEC.md)

## What to build

Plain `bbr` enters the TUI at once.
On a branch, it shows the Detecting Frame "Detecting PR for `<branch>`…".
One AdjacentPullRequest opens its review Session.
Every other case opens the Browser with the Browser Start from the spec.
`bbr <repo-slug>` detects in that Repository.
`bbr detect` prints the same outcome without the TUI.

## Scope

- Replace `startup.resolve` and `startup.Entry` in `src/startup.zig` with `inspect`, `detect`, `Inspection`, `Outcome`, `Start`, and `describe`.
- Compare the Remote Workspace with the Credential Workspace without ASCII case.
- Call `startup.inspect` in `openTui` in `src/main.zig`, and pass a `startup.Start` to `app.run`.
- Replace `RunCtx.repo` and the initial `OwnedReviewIdentity` argument with `RunCtx.start`.
- Add the input `detect_startup`, the command `detect_adjacent_pull_requests`, and the completion `adjacent_detected`, with `deinit` and `launchFailed` arms.
- Add the `detecting` Interaction Context and `Projection.detecting`.
- Add `render.drawDetecting` with `layouts.loading`.
- Rewrite `detectRun` with `startup.describe`.
- Update `usage` in `src/main.zig`.
- Add `tests/detect_cli_test.py` and register it in the `test-cli` step of `build.zig`.

## Acceptance criteria

- [x] Each row of the `Inspection` table in the spec gives its result, and `inspect` sends no request.
- [x] A Remote in another Workspace gives a plain Browser.
- [x] A Remote Workspace that differs only in ASCII case counts as the configured Workspace.
- [x] Each row of the `Outcome` table in the spec gives its result.
- [x] Two AdjacentPullRequests focus the highest PullRequestId.
- [x] A failed list request without an argument gives a plain Browser, and with an argument keeps that Repository expanded.
- [x] The Detecting Frame names the branch, and only `quit` resolves in it.
- [x] `q` during detection requests shutdown at once.
- [x] An `.open` outcome loads the review Session, and a `.browse` outcome shows the Browser with its Browser Start.
- [x] A failed detection shows no note in the TUI.
- [x] A launch failure of the detection command opens the plain Browser.
- [x] The URL path and the `<repo> <id>` path do not change.
- [x] `startup.describe` prints each line of the `bbr detect` table, and a failure adds `reason: <error name>`.
- [x] `bbr detect` outside Git prints `resolved: browser` and exits `0`.

## Tests that prove it

- The test "M24 startup every Inspection and Outcome" and the other `M24 startup` tests in `src/startup.zig`.
- `M24 startup` Presentation tests in `src/tui/presentation.zig`.
- The render test for the Detecting Frame in `src/tui/render.zig`.
- The extended launch-failure test in `src/tui/presentation.zig`.
- `tests/detect_cli_test.py`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test-cli`
- `zig build test --summary all`

## Completion

This commit implements the ticket.

### Change summary

- `src/startup.zig` replaces `resolve` and `Entry` with `Input`, `Target`, `Detection`, `Browse`, `Inspection`, `Outcome`, `Start`, `start`, `inspect`, `detect`, and `describe`.
  `inspect` takes no Client, so it sends no request. Every Git error gives a Browser Start.
  `inspect` compares the Remote Workspace with the Credential Workspace without ASCII case.
  `detect` focuses the highest PullRequestId when two or more AdjacentPullRequests exist.
  `start` keeps the URL path and the `<repo> <id>` path, and calls `inspect` for the other paths.
- `openTui` in `src/main.zig` calls `startup.start` before the TUI and passes the result in `RunCtx.start`.
  It no longer prints "N open PRs; opening #M" or "no open pull requests".
- `app.Start` replaces `RunCtx.repo` and the initial `OwnedReviewIdentity` argument of `app.run`.
  Its `review` arm holds the key of a LocalReview or the demo. Its `remote` arm holds a `startup.Start`.
  `presentation_adapter.startInput` turns a `startup.Start` into `choose_pull_request`, `detect_startup`, or `start_browser`.
- The input `detect_startup` queues the command `detect_adjacent_pull_requests` and sets `Presentation.surface` to `.detecting`.
  `Projection.detecting` holds the branch, and `render.drawDetecting` paints " Detecting PR for <branch>…" with `layouts.loading`.
- The completion `adjacent_detected` carries an `AdjacentOutcome`.
  `.open` runs the `choose_pull_request` path. `.browse` runs `Presentation.startBrowser`, so the Summary Cache loads first.
  The command has arms in `OwnedCommand.deinit`, `launchFailed`, `setCommandId`, `takeCommand`, and `LaunchFailureFixture`. A launch failure gives the plain Browser.
- The Interaction Context `detecting` supports only `quit`. `q` requests shutdown at once, and shutdown waits for the detection worker.
- `presentation_adapter.detectAdjacentPullRequests` runs `startup.detect` on a worker that `drainPresentationCommands` launches.
- The status in the Detecting Frame shows only the hint `q quit`, or a message such as "shutting down…".
- `detectRun` runs `startup.inspect`, then `startup.detect` only for an `Inspection.detect`, and prints the outcome with `startup.describe`.
  It keeps the `branch:` and `remote:` lines. It creates no HTTP client for a Browser Start and never touches the Summary Cache.
- `usage` describes the new plain `bbr` and `bbr <repo-slug>` startup and lists `bbr detect`.
- `tests/detect_cli_test.py` is new, and the `test-cli` step of `build.zig` runs it.

### Defaults chosen

- `app.Start` wraps `startup.Start`, because a LocalReview and the demo need an `OwnedReviewIdentity` that `src/startup.zig` cannot name.
- `Outcome` has a third arm, `failed`, with the reason and the Browser Start. `describe` needs the reason, and the TUI treats `failed` like `browse`.
- `startup.start` is a small addition. It holds the URL and `<repo> <id>` paths that `resolve` held, so `openTui` stays short and the URL test stays in `src/startup.zig`.
- `bbr detect` prints `reason:` only for a failed list request. A Git error already shows in the `branch:` and `remote:` lines.
- `bbr detect` writes to stderr, as the old command did.
- The Detecting Frame text has no backticks: " Detecting PR for feature/x…". This matches the " Loading PR #N…" frame.
- A Repository or branch name longer than 256 bytes gives the plain Browser, because `browser.Name` holds at most 256 bytes.
- An out-of-memory failure of the `.open` path returns the error from `dispatch`, as the `choose_pull_request` input does.

### Checks

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-browser`: "9/9 steps succeeded; 74/74 tests passed". The baseline was 64.
- `zig build test-cli`: "10/10 steps succeeded". It runs `tests/detect_cli_test.py`.
- `zig build test --summary all`: "25/25 steps succeeded; 1440/1440 tests passed". The baseline was 1437. This commit adds 10 tests and deletes 7 superseded startup tests.
- `python3 tools/check_agent_docs.py`: pass.

### Tests

- `src/startup.zig`: "M24 startup every Inspection and Outcome", "M24 startup a Remote in another Workspace gives a plain Browser, and ASCII case does not matter", "M24 startup the URL and the <repo> <id> paths open directly without Git", and "M24 startup describe prints each bbr detect line".
- `src/tui/presentation.zig`: "M24 startup detect_startup shows the Detecting Frame, and only q resolves in it", "M24 startup an open outcome loads its review Session, and a browse outcome starts the Browser with its Browser Start", and "M24 startup a failed launch of the detection opens the plain Browser with no note".
  The test "every OwnedCommand launch failure keeps its correlation and frees the command" covers `detect_adjacent_pull_requests`.
- `src/tui/presentation_adapter.zig`: "M24 startup the detection worker opens one AdjacentPullRequest and turns a failure into a plain Browser".
- `src/tui/keymap.zig`: "M24 startup only quit resolves in the Detecting Frame".
- `src/tui/render.zig`: "M24 startup the Detecting Frame names the branch in the loading dialog".
- `tests/detect_cli_test.py`: `bbr detect` outside Git prints `resolved: browser` and exits `0`. `bbr detect pr-webapp` prints `resolved: browser pr-webapp expanded`. A dead proxy proves that no request goes out, and no state directory appears.
- This commit deletes the seven old startup tests. They tested `resolve`, the pre-filtered Picker, the all-open Picker, and `empty`, which no longer exist.

### Review

- I read the full diff.
- I found no leak in the test allocator runs and no AGENTS.md rule violation.
- Ticket 06 adds the Startup Detection row to the AGENTS.md rule table. The test and the script that the row names exist now.
- Ticket 06 also updates `FEATURES.md` line 12, which still describes the pre-filtered Picker.
