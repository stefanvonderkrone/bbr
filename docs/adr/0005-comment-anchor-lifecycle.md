# Comment anchor lifecycle: current / moved / outdated

Every comment Anchor binds to a **commit + path + line** (plus a few captured context lines),
not just a line. When the diff being viewed differs from the commit a comment was authored on,
the comment resolves to an **AnchorState**: `current`, `moved`, or `outdated`. Outdated
comments are **never hidden** — they are shown in a per-file collapsible using their captured
context, so a comment whose line no longer exists is still readable.

## Who computes the state

- **Remote (Bitbucket) comments** — we display **Bitbucket's** outdated verdict and original
  hunk context. Bitbucket is authoritative for its own comments (consistent with ADR-0001);
  we do not re-derive it and risk divergence.
- **Local comments and pending Drafts** — there is no server, so we compute the state
  ourselves by **diff-walking**: `git diff <anchor_commit> <current_ref> -- <path>` and mapping
  the old line forward.

## Consequences

- Comments and Drafts store the commit hash they were authored against, plus captured context
  lines, in SQLite.
- This is why local review needs the GitClient (ADR-0004): the diff-walk is how local
  outdatedness is even knowable.
