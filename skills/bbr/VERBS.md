# bbr api verbs

Each recipe and example passes only flags that its verb takes. Run `bbr api VERB --help` for a flag that none of them shows.

A PullRequest is always `--pull-request-id`, a Comment `--comment-id`, and a Task `--task-id`. No verb takes --id.

## Recipes

Replace `REPO`, `42`, and `7` with real values. Replace `UUID` with the `uuid` of `bbr api whoami --json`, which includes its braces. A write recipe still needs the approval of the mutation guard in SKILL.md.

```sh
# Find the PullRequest of the current Branch
bbr api list-pull-requests --repository REPO --source-branch "$(git branch --show-current)" --state OPEN --json
# Read every Comment on a PullRequest
bbr api list-comments --repository REPO --pull-request-id 42 --json
# Read only the Comments of other accounts, such as review findings
bbr api list-comments --repository REPO --pull-request-id 42 --query 'user.uuid != "UUID"' --json
# Bitbucket cannot filter resolution or parent. Read the `resolved` and `parent_id` fields of the JSON instead.
# Wrap each inline.path term in parentheses, such as 'user.uuid != "UUID" AND (inline.path != null)'.
# Reply to Comment 7 (write)
bbr api create-comment --repository REPO --pull-request-id 42 --parent-id 7 --body-file reply.md
# Replace the PullRequest description (write)
bbr api update-pull-request --repository REPO --pull-request-id 42 --description-file body.md
```

## Workspaces

- `list-workspaces` — list Workspaces for the account. Example: `bbr api list-workspaces --pagelen 10 --no-follow`
- `get-workspace` — get one Workspace. Example: `bbr api get-workspace --workspace demo`
- `list-workspace-members`. List Workspace Member UUIDs, display names, and nicknames. Example: `bbr api list-workspace-members --json`
- `search-workspace-members`. Find member UUIDs by name with local ranked matches. Repeat `--name` to share one member list acquisition. Example: `bbr api search-workspace-members --name 'Ada Lovelace' --name 'Grace Hopper' --json`

## Repositories

- `list-repositories` — list Repositories in a Workspace. Example: `bbr api list-repositories --workspace demo --limit 10`
- `get-repository` — get one Repository. Example: `bbr api get-repository --workspace demo --repository sample`

## Branches

- `create-branch`. Create a Branch from a commit hash or an existing branch name. Example: `bbr api create-branch --repository sample --name feature/example --target main`
- `list-branches`. List Branches with filters and page controls. Example: `bbr api list-branches --repository sample --sort name --limit 10`
- `get-branch`. Read a Branch, its target Commit, and its merge strategies. Example: `bbr api get-branch --repository sample --name feature/example`

## PullRequests

- `list-pull-requests` — list PullRequests in a Repository. Example: `bbr api list-pull-requests --repository sample --state OPEN --pagelen 10 --page 2 --no-follow`
- `list-workspace-pull-requests`. List PullRequests across the Workspace by author UUID, or in the named Repositories by author or reviewer UUID. Example: `bbr api list-workspace-pull-requests --reviewer '{reviewer}' --repository sample --repository other --state OPEN --state MERGED --limit 20`
- `get-pull-request` — get one PullRequest. Example: `bbr api get-pull-request --repository sample --pull-request-id 42`
- `list-default-reviewers`. List the Default Reviewers that the Bitbucket web UI adds to a new PullRequest. `--effective` adds the Default Reviewers of the Project. Example: `bbr api list-default-reviewers --repository sample --effective`
- `create-pull-request`. Create a Ready PullRequest or a Draft PullRequest. Example: `bbr api create-pull-request --repository sample --title 'Example change' --source-branch feature/example --draft true`
- `update-pull-request`. Update supplied fields on an open PullRequest. Example: `bbr api update-pull-request --repository sample --pull-request-id 42 --draft false`
- `decline-pull-request`. Close a PullRequest without merging. Example: `bbr api decline-pull-request --repository sample --pull-request-id 42`
- `list-commit-pull-requests`. List PullRequests where Bitbucket reviewed a commit. Example: `bbr api list-commit-pull-requests --repository sample --commit abc123 --limit 10`
- `list-commits` — list commits by PullRequest, revision, or from..to range. Example: `bbr api list-commits --repository sample --revision main --limit 10`

## Files (raw bytes)

- `get-diff` — raw diff of a PullRequest. Example: `bbr api get-diff --repository sample --pull-request-id 42 --out review.diff`
- `get-compare-diff` — raw diff between two commits. Example: `bbr api get-compare-diff --repository sample --from abc123 --to def456 --patch`
- `get-blob` — file bytes at a commit. Example: `bbr api get-blob --repository sample --commit abc123 --path src/main.zig --out main.zig`
- `check-blob` — verify file metadata at a commit. Example: `bbr api check-blob --repository sample --commit abc123 --path src/main.zig --attributes -`

## Comments

- `list-comments` — list Comments on a PullRequest. Example: `bbr api list-comments --repository sample --pull-request-id 42 --no-head --limit 10`
- `get-comment` — get one Comment. Example: `bbr api get-comment --repository sample --pull-request-id 42 --comment-id 7`
- `create-comment` — create a Comment or reply (live). Example: `bbr api create-comment --repository sample --pull-request-id 42 --body 'Please add a test.'`. Reply: `bbr api create-comment --repository sample --pull-request-id 42 --parent-id 7 --body 'Done.'`
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
- `get-user`. Read public account information by Atlassian account ID or Bitbucket UUID. Example: `bbr api get-user --user-id ACCOUNT_ID --json`
- `get-verdict` — Reviewer Verdict for an account. Example: `bbr api get-verdict --repository sample --pull-request-id 42 --uuid '{reviewer}'`
- `set-verdict` — set Reviewer Verdict (live). bbr refuses to set a Reviewer Verdict on your own PullRequest. Example: `bbr api set-verdict --repository sample --pull-request-id 42 --verdict approved --expected-source-commit abc123`
