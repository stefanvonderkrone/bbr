# Git

Local git integration: what branch/worktree you are in, resolving refs to commits, and
producing local diffs so a branch can be reviewed offline without Bitbucket. The only context
that shells out to the `git` binary, behind the `GitClient` seam.

## Language

**GitClient**:
The seam over the local `git` binary: current branch, the tracking Remote, worktree list, ref resolution, diff between refs, and file content at a ref. Shells out now; fakeable with fixtures in tests. Its read-only inspection subset (branch + Remote) powers startup PR detection; its diffing subset powers local review.
_Avoid_: repo, libgit, vcs.

**Remote**:
The tracking remote (`origin`) URL, parsed to `(workspace, repo_slug)`. Handles both SSH (`git@bitbucket.org:check24/<repo>.git`) and HTTPS forms — including this machine's `url.insteadof` rewrites.
_Avoid_: origin, upstream, url.

**WorkingCopy**:
The checkout rooted at the current working directory — the thing whose branch and worktree we detect to decide what to review.
_Avoid_: repo, clone, workdir.

**Worktree**:
A git worktree: a checkout with its own branch sharing one object store. bbr detects the branch of the *current* worktree, so linked worktrees each review their own branch.
_Avoid_: workdir, checkout.

**Ref**:
A branch name or commit-ish that resolves to a commit hash. Local review diffs a source Ref against a base Ref.
_Avoid_: revision, branch (a branch is one kind of Ref), pointer.

**BaseRef**:
The Ref a branch is compared against in local review (default `HEAD` of the destination branch, or a user-chosen Ref). Committed refs only in the MVP — no dirty working-tree diffs yet.
_Avoid_: target, upstream, main.

**AdjacentPullRequest**:
The open Bitbucket PullRequest whose source branch matches the WorkingCopy's current branch, in the repo named by the Remote — the primary startup entry to remote review. Zero matches → the no-PR chooser; more than one → a pre-filtered Picker.
_Avoid_: linked PR, matching PR, my PR.
