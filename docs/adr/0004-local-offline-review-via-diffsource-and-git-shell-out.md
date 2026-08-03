# Local (offline) review via a DiffSource abstraction and git shell-out

bbr reviews changes from either a Bitbucket PullRequest **or** a local branch diffed against a
base ref, with no Bitbucket involved. Both feed a common **DiffSource** that yields unified
diff text, so the entire parser, renderer, and comment UI are source-agnostic; only the source
and the comment target differ. Local git operations (current branch, worktree detection, ref
resolution, `diff` between refs, file content at a ref) go through a **`GitClient` seam that
shells out to the `git` binary** rather than linking libgit2.

DiffSource stops at owned unified diff text. Thread acquisition, ReviewHeader metadata, File
Enrichment, Anchor resolution, and Submission do not belong to its interface; their lifecycles
and source-specific policies remain behind the Published review module.

## Considered options

- **libgit2** — richer API, but a heavyweight C dependency and more build friction, for
  operations we can get from the `git` CLI.
- **Shell out to `git`** (chosen) — no extra C dependency, trivially faked with fixtures for
  tests, matches our other seams.

## Consequences

- Local-mode comments have `CommentTarget = local`: they persist in SQLite and never enter
  Submission (there is nothing to submit to).
- CommentTarget is an invariant of a Pending Review, so local and Bitbucket Drafts never mix.
  A possible future conversion from local Drafts to remote Drafts would explicitly copy them
  between distinct Reviews; conversion is outside the local-review MVP.
- A LocalReview is scoped by a logical ReviewRepository plus BaseRef and SourceRef. Durability
  assigns a stable ReviewRepositoryId and resolves both normalized Remote and canonical Git
  common-directory aliases to it, so linked Worktrees and separate clones share Drafts without
  identity changing when an alias is added. Credentials and raw URL spelling never enter aliases.
- Resolving a Remote alias and common-directory alias to different ReviewRepositoryIds is an
  explicit identity conflict; M14 refuses to merge them automatically.
- Separate clones share identity only through a common normalized Remote alias. When no such
  alias exists, M14 assigns distinct ReviewRepositoryIds because it cannot prove the clones are
  the same logical repository. Linked Worktrees still share via their common-directory alias;
  explicit identity relinking or merging is scheduled for M18.
- When several Remotes exist, ReviewRepository identity uses the SourceRef's tracking Remote,
  then `origin`, then the common-directory fallback; it never selects another Remote arbitrarily.
- BaseRef and SourceRef use canonical Ref identities rather than user-entered spellings or their
  currently resolved commits. Equivalent spellings share a LocalReview; distinct named Refs do
  not collapse merely because they currently resolve to the same commit. An explicit commit-ish
  canonicalizes to its full immutable commit hash.
- Local review supports any Git repository; only AdjacentPullRequest discovery and remote review
  require a Bitbucket Remote. Remote normalization for ReviewRepository identity is therefore
  generic over hosts and transport spellings.
- Shared LocalReviews require the durability implementation to prevent lost Draft additions and
  TempId collisions across concurrent bbr processes. M14 does not provide live synchronization;
  another process's changes become visible after explicit refresh or reopening the Review.
- A clone that lacks the commit stored on a shared Draft's Anchor reports resolution unavailable;
  absence of the commit is not evidence that the Anchor is outdated.
- The MVP supports **committed refs only** (branch vs base commit) so every Anchor binds to a
  stable commit + line. M18 owns dirty working-tree diffs and the required fuzzy content-based
  anchoring.
- From a local checkout, Git can find the **AdjacentPullRequest** (open PR whose source branch
  matches the current branch/worktree) to open a remote review instead.
