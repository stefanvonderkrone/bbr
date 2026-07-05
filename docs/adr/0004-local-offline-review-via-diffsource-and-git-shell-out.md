# Local (offline) review via a DiffSource abstraction and git shell-out

bbr reviews changes from either a Bitbucket PullRequest **or** a local branch diffed against a
base ref, with no Bitbucket involved. Both feed a common **DiffSource** that yields unified
diff text, so the entire parser, renderer, and comment UI are source-agnostic; only the source
and the comment target differ. Local git operations (current branch, worktree detection, ref
resolution, `diff` between refs, file content at a ref) go through a **`GitClient` seam that
shells out to the `git` binary** rather than linking libgit2.

## Considered options

- **libgit2** — richer API, but a heavyweight C dependency and more build friction, for
  operations we can get from the `git` CLI.
- **Shell out to `git`** (chosen) — no extra C dependency, trivially faked with fixtures for
  tests, matches our other seams.

## Consequences

- Local-mode comments have `CommentTarget = local`: they persist in SQLite and never enter
  Submission (there is nothing to submit to).
- The MVP supports **committed refs only** (branch vs base commit) so every Anchor binds to a
  stable commit + line. Dirty working-tree diffs — which would force fuzzy content-based
  anchoring — are a deliberately deferred enhancement.
- From a local checkout, Git can find the **AdjacentPullRequest** (open PR whose source branch
  matches the current branch/worktree) to open a remote review instead.
