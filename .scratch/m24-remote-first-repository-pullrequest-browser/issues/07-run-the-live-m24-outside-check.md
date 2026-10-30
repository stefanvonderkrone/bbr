# 07: Run the live M24 outside check

Status: ready-for-human
Blocked by: 06
Spec: [M24 spec](../SPEC.md)

## What to build

A human proves M24 on the real Workspace.
This check needs a Bitbucket Credential and real Repositories, so an agent cannot run it.

## Steps

Shape check:

1. Run `bbr check-browser` with no argument.
2. Run `bbr check-browser <repo-slug>` on a Repository with an approved PullRequest and a PullRequest with changes requested.
3. Compare the printed counts with the Bitbucket web UI.

Startup:

1. On a branch with one open PullRequest, run `bbr`. Make sure that its review Session opens.
2. On a branch with no open PullRequest, run `bbr`. Make sure that the Browser opens with the Repository expanded and focused.
3. In a directory outside Git, run `bbr`. Make sure that the plain Browser opens with no note.
4. Run `bbr detect` in each of the three places, and record each outcome line.
5. Press `q` during the Detecting Frame. Make sure that bbr exits.

Browser:

1. Delete `$XDG_STATE_HOME/bbr/browser-cache.json`.
   Measure the time from `bbr` outside Git to the first Browser frame with rows.
2. Quit and run `bbr` again. Measure the time to the first frame with cached rows.
3. Route bbr through an HTTPS proxy that logs requests.
   Expand every Repository one by one, and count the requests.
4. Make sure that no response is a `429`.
5. Open a PullRequest with Enter, press `b`, and make sure that the expansion, Selection, and scroll are the same.
6. Press `s` twice, and make sure that the cursor stays on the same row.

## Acceptance criteria

- [ ] `bbr check-browser` shows participant counts that match the web UI, or the gap is recorded.
- [ ] Each startup place opens the outcome that the spec requires.
- [ ] Each `bbr detect` line matches the TUI outcome.
- [ ] The cold and cached times to the first Browser frame are recorded.
- [ ] The request count for a full expansion is recorded, and no `429` occurs.
- [ ] The return with `b` and both Sort changes keep the Browser state.
- [ ] The results, the Workspace, and the bbr commit are recorded under `## Completion` in this ticket.
