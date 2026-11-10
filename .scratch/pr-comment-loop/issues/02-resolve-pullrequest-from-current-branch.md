# Find the PullRequest of the current Branch

Status: needs-triage
Blocked by: none

## Problem

Before an agent reads the Comments, it runs 3 to 5 commands: `git remote -v`, `git branch --show-current`, `bbr api list-pull-requests --source-branch NAME --json`, and then `list-comments` with the PullRequest id. The pr-webapp retro found 48 `list-pull-requests` calls in 22 sessions for this lookup.

## Proposal

Let the Comment verbs (`list-comments`, `create-comment`, `get-comment`, `update-comment`, `resolve-comment`, `reopen-comment`) find the PullRequest when the call has no `--pull-request-id`:

- Read the Repository from the Git remote and the Branch from the current checkout.
- Use the one open PullRequest whose source Branch is the current Branch.
- Fail with a clear message when there is no open PullRequest, or more than one.

Triage decides the verb scope and if `--repository` can also come from the Git remote.

## Acceptance criteria

- [ ] `bbr api list-comments` with no `--pull-request-id` in a checkout of a PullRequest Branch lists the Comments of that PullRequest.
- [ ] A Branch with no open PullRequest, or with more than one, fails with a message that names the Branch.
- [ ] An explicit `--pull-request-id` still wins.
- [ ] `skills/bbr/VERBS.md` and the verb help describe the default.
- [ ] `zig build test` passes.
