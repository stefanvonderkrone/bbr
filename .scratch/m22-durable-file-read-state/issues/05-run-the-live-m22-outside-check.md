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

## Comments

### Notes for the human

Tickets 01 to 04 are resolved on the branch `m22-durable-file-read-state`.
The commits are 9231fcb, 70f6331, fca6067, 3d7109e, and 584985b.
The hermetic suite passes with 1423 tests.

Build bbr from the branch:

```sh
cd /Volumes/Work/t3-code/m22-durable-file-read-state
git log --oneline -1
zig build
```

Record the `git log` hash under `## Completion`.

Open the RemoteReview with a PullRequest URL, or with a Repository slug and an id:

```sh
zig build run -- https://bitbucket.org/<workspace>/<repository>/pull-requests/<id>
```

Open the LocalReview from a checkout of the test Repository:

```sh
cd <test-repository>
/Volumes/Work/t3-code/m22-durable-file-read-state/zig-out/bin/bbr local <base-ref> <source-ref>
```

What to look for:

- In the File Tree, an unread File row is bold. A read File row has regular weight.
- A Directory row is bold while any File below it is unread.
- `m` works on a File row in the Sidebar and in the DiffPane. `m` does nothing on a Directory row.
- The Command Palette (`Ctrl-p`) lists "Toggle File Read".
- A binary File without blob ids shows "File cannot be verified, so it stays unread" after `m`.

To see the Bitbucket blob ids for step 7, get the RawDiff of the PullRequest:

```sh
curl -s -u '<email>:<api-token>' \
  'https://api.bitbucket.org/2.0/repositories/<workspace>/<repository>/pullrequests/<id>/diff' \
  -L | grep -A1 '^diff --git .*<binary-file>'
```

Look for an `index <old>..<new>` line under the binary File. Record the id length.
If Bitbucket sends no `index` line, the binary File stays bold after `m`. This is the expected conservative result.

To check the stored receipts directly:

```sh
sqlite3 "${XDG_STATE_HOME:-$HOME/.local/state}/bbr/pending.db" \
  'SELECT review_kind, workspace, repository, pr_id, base_ref, source_ref, path FROM file_read_receipts;'
```

A RemoteReview row has `review_kind` 0. A LocalReview row has `review_kind` 1.
After a refresh, a stale receipt stays in the table until the next `m` on that path.
This is the approved behavior from decision 3 of the brief.

For LocalReview step 5, run `git config core.abbrev 12` in the test Repository.
Remove it afterward with `git config --unset core.abbrev`.
