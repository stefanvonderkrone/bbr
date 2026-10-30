# 05: Detect the startup target inside the TUI

Status: ready-for-agent
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

- [ ] Each row of the `Inspection` table in the spec gives its result, and `inspect` sends no request.
- [ ] A Remote in another Workspace gives a plain Browser.
- [ ] A Remote Workspace that differs only in ASCII case counts as the configured Workspace.
- [ ] Each row of the `Outcome` table in the spec gives its result.
- [ ] Two AdjacentPullRequests focus the highest PullRequestId.
- [ ] A failed list request without an argument gives a plain Browser, and with an argument keeps that Repository expanded.
- [ ] The Detecting Frame names the branch, and only `quit` resolves in it.
- [ ] `q` during detection requests shutdown at once.
- [ ] An `.open` outcome loads the review Session, and a `.browse` outcome shows the Browser with its Browser Start.
- [ ] A failed detection shows no note in the TUI.
- [ ] A launch failure of the detection command opens the plain Browser.
- [ ] The URL path and the `<repo> <id>` path do not change.
- [ ] `startup.describe` prints each line of the `bbr detect` table, and a failure adds `reason: <error name>`.
- [ ] `bbr detect` outside Git prints `resolved: browser` and exits `0`.

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
