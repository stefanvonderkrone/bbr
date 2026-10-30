# 05: Run the live M22 outside check

Status: ready-for-human
Blocked by: 04
Spec: [M22 spec](../SPEC.md)

## What to build

A human proves M22 on a live PullRequest and on a LocalReview.
This check needs a Bitbucket Credential and a push to a real branch, so an agent cannot run it.

## Steps

RemoteReview:

1. Open a PullRequest with at least three text Files and, if possible, one binary File.
2. Press `m` on every File, and make sure that every File row shows regular weight.
3. Quit bbr and open the PullRequest again. Make sure that every File stays read.
4. Push one commit that changes one text File.
5. Merge the destination branch into the source branch and push.
6. Press `R`. Make sure that only the changed File is bold.
7. Note whether the Bitbucket RawDiff has an `index` line for the binary File, and note the id length.
8. Switch to another PullRequest with `p`, then switch back. Make sure that the read state is the same.

LocalReview:

1. Open a LocalReview with `bbr local` on a branch with at least three changed Files and one binary File.
2. Press `m` on every File.
3. Add a commit on the SourceRef that changes one File.
4. Press `R`. Make sure that only the changed File is bold.
5. Set `git config core.abbrev 12`, press `R`, and make sure that no binary File becomes bold.

## Acceptance criteria

- [ ] On the RemoteReview, only the changed File is bold after the push, the merge, and `R`.
- [ ] On the RemoteReview, read state survives a restart and a PullRequest switch.
- [ ] On the LocalReview, only the changed File is bold after the new commit and `R`.
- [ ] A `core.abbrev` change does not reset a LocalReview binary File.
- [ ] The result records whether Bitbucket sends `index` ids for binary Files, and their length.
- [ ] The results, the PullRequest, and the bbr commit are recorded under `## Completion` in this ticket.
