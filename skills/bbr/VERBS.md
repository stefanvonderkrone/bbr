# bbr api verbs

28 verbs. Run `bbr api VERB --help` for flags. No flag tables here.

## Workspaces

- `list-workspaces` — list Workspaces for the account. Example: `bbr api list-workspaces --pagelen 10 --no-follow`
- `get-workspace` — get one Workspace. Example: `bbr api get-workspace --workspace demo`

## Repositories

- `list-repositories` — list Repositories in a Workspace. Example: `bbr api list-repositories --workspace demo --limit 10`
- `get-repository` — get one Repository. Example: `bbr api get-repository --workspace demo --repository sample`

## PullRequests

- `list-pull-requests` — list PullRequests in a Repository. Example: `bbr api list-pull-requests --repository sample --state OPEN --pagelen 10 --page 2 --no-follow`
- `get-pull-request` — get one PullRequest. Example: `bbr api get-pull-request --repository sample --pull-request-id 42`
- `list-commits` — list commits by PullRequest, revision, or from..to range. Example: `bbr api list-commits --repository sample --revision main --limit 10`

## Files (raw bytes)

- `get-diff` — raw diff of a PullRequest. Example: `bbr api get-diff --repository sample --pull-request-id 42 --out review.diff`
- `get-compare-diff` — raw diff between two commits. Example: `bbr api get-compare-diff --repository sample --from abc123 --to def456 --patch`
- `get-blob` — file bytes at a commit. Example: `bbr api get-blob --repository sample --commit abc123 --path src/main.zig --out main.zig`
- `check-blob` — verify file metadata at a commit. Example: `bbr api check-blob --repository sample --commit abc123 --path src/main.zig --attributes -`

## Comments

- `list-comments` — list Comments on a PullRequest. Example: `bbr api list-comments --repository sample --pull-request-id 42 --no-head --limit 10`
- `get-comment` — get one Comment. Example: `bbr api get-comment --repository sample --pull-request-id 42 --comment-id 7`
- `create-comment` — create a Comment or reply (live). Example: `bbr api create-comment --repository sample --pull-request-id 42 --body 'Please add a test.'`
- `update-comment` — edit a Comment body (live). Example: `bbr api update-comment --repository sample --pull-request-id 42 --comment-id 7 --body 'Please test this case.'`
- `delete-comment` — delete a Comment (live). Example: `bbr api delete-comment --repository sample --pull-request-id 42 --comment-id 7`
- `resolve-comment` — resolve a thread without editing prose (live). Example: `bbr api resolve-comment --repository sample --pull-request-id 42 --comment-id 7`
- `reopen-comment` — reopen a thread (live). Example: `bbr api reopen-comment --repository sample --pull-request-id 42 --comment-id 7`

## Tasks

- `list-tasks` — list Tasks on a PullRequest. Example: `bbr api list-tasks --repository sample --pull-request-id 42 --state-filter UNRESOLVED --limit 10`
- `get-task` — get one Task. Example: `bbr api get-task --repository sample --pull-request-id 42 --task-id 3`
- `create-task` — create a Task (live). Example: `bbr api create-task --repository sample --pull-request-id 42 --content 'Add a test.'`
- `update-task` — update Task content and/or state (live). Example: `bbr api update-task --repository sample --pull-request-id 42 --task-id 3 --state RESOLVED`
- `delete-task` — delete a Task (live). Example: `bbr api delete-task --repository sample --pull-request-id 42 --task-id 3`
- `resolve-task` — resolve a Task (live). Example: `bbr api resolve-task --repository sample --pull-request-id 42 --task-id 3`
- `reopen-task` — reopen a Task (live). Example: `bbr api reopen-task --repository sample --pull-request-id 42 --task-id 3`

## Identity

- `whoami` — Authenticated Account UUID. Example: `bbr api whoami --json`
- `get-verdict` — Reviewer Verdict for an account. Example: `bbr api get-verdict --repository sample --pull-request-id 42 --uuid '{reviewer}'`
- `set-verdict` — set Reviewer Verdict (live). Example: `bbr api set-verdict --repository sample --pull-request-id 42 --verdict approved --expected-source-commit abc123`
