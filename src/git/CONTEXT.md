# Git

Local git integration: what branch/worktree you are in, resolving refs to commits, and
producing local diffs so a branch can be reviewed offline without Bitbucket. The only context
that shells out to the `git` binary, behind the `GitClient` seam.

## Language

**GitClient**:
The seam over the local `git` binary: current branch, the tracking Remote, worktree list, ref resolution, diff between refs, and file content at a ref. Shells out now; fakeable with fixtures in tests. Its read-only inspection subset (branch + Remote) powers startup PR detection; its diffing subset powers local review.
_Avoid_: repo, libgit, vcs.

**Remote**:
A configured Git remote normalized to a credential-free host and repository path, independent of transport spelling and `url.insteadof` aliases. ReviewRepository identity uses the SourceRef's tracking Remote, then `origin`, and otherwise no Remote; a Bitbucket Remote can additionally be translated to a Workspace and Repository for AdjacentPullRequest discovery.
_Avoid_: origin (one possible name), upstream, raw URL.

**WorkingCopy**:
The checkout rooted at the current working directory — the thing whose branch and worktree we detect to decide what to review.
_Avoid_: repo, clone, workdir.

**ReviewRepository**:
The logical repository that scopes LocalReviews, represented durably by a ReviewRepositoryId. Normalized Remote and local Git common-directory aliases resolve to that stable identity, allowing Worktrees and clones to share Drafts without changing identity when aliases are added.
_Avoid_: WorkingCopy (one checkout), object store, raw remote URL.

**ReviewRepositoryId**:
The stable local identifier assigned to a ReviewRepository. Alias conflicts never merge ReviewRepositoryIds automatically; they require explicit resolution.
_Avoid_: remote hash, common-directory path, Repository slug.

Separate clones share a ReviewRepositoryId only when a normalized Remote alias connects them. Without one, M14 cannot prove they are the same logical repository and assigns distinct identities; linked Worktrees still share through their common-directory alias. M18 owns the explicit relinking/merging workflow.

**Worktree**:
A git worktree: a checkout with its own branch sharing one object store. bbr detects the branch of the *current* worktree, so linked worktrees each review their own branch.
_Avoid_: workdir, checkout.

**Ref**:
A canonical branch, remote-tracking branch, tag, or full commit hash that resolves to a commit. Equivalent input spellings canonicalize to one Ref, while distinct named Refs remain distinct even when they currently resolve to the same commit.
_Avoid_: revision, branch (a branch is one kind of Ref), pointer.

**BaseRef**:
The Ref a SourceRef is compared against in a LocalReview. The reviewer may choose it explicitly; otherwise bbr uses Git's locally recorded remote default Ref and refuses to guess when none is available. Committed refs only in the MVP — no dirty working-tree diffs yet.
_Avoid_: target, upstream, main.

**SourceRef**:
The Ref whose committed changes are being reviewed against a BaseRef. It normally names the current Worktree's branch and may resolve to a newer commit while remaining part of the same LocalReview.
_Avoid_: branch under review, head, feature branch.

**LocalReview**:
A review identified by a ReviewRepository, BaseRef, and SourceRef. It remains the same LocalReview across Worktrees and clones and as either Ref advances; each load resolves both Refs anew so existing Anchors can become current, moved, or outdated.
_Avoid_: local session, commit-pair review, offline PR.

**AdjacentPullRequest**:
The open Bitbucket PullRequest whose source branch matches the WorkingCopy's current branch, in the Bitbucket Repository identified by its Remote — the primary startup entry to remote review. Zero matches → the no-PR chooser; more than one → a pre-filtered Picker.
_Avoid_: linked PR, matching PR, my PR.
