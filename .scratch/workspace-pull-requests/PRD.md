# Workspace PullRequests by Author or Reviewer

Status: ready-for-agent

## Problem

An agent or a user wants every PullRequest in a Workspace that one account authored or reviews.
Bitbucket Cloud has an author endpoint for one Workspace, `GET /2.0/workspaces/{workspace}/pullrequests/{selected_user}`.
Bitbucket Cloud has no reviewer endpoint.
The only reviewer filter is `q=reviewers.uuid="{uuid}"` on `GET /2.0/repositories/{workspace}/{repo}/pullrequests`, one Repository at a time.
Today `bbr api` can only run that filter on one Repository.

## Command

```sh
bbr api list-workspace-pull-requests (--author UUID | --reviewer UUID | --author UUID --reviewer UUID)
    [--state OPEN|MERGED|DECLINED|SUPERSEDED]...
    [--query Q] [--concurrency N] [--limit N] [--json]
```

- `--author` and `--reviewer` each take one account UUID. The command needs at least one of them.
- `--state` repeats. The default is `OPEN`. Without a `q` filter, each value becomes one `state=` parameter. With a `q` filter, the states go into `q`, because Bitbucket then ignores `state=`.
- `--query` is a Bitbucket `q` expression. The command joins it to its own filter with `AND (...)`.
- `--limit` caps the total number of PullRequests in the output.
- `--concurrency` sets the number of parallel Repository requests in reviewer mode. The default and the CPU cap follow `search-workspace-members`.

## Behavior

- With `--author`, the command follows the pages of the author endpoint. A `--reviewer` value becomes `reviewers.uuid="..."` in `q`.
- With only `--reviewer`, the command lists every Repository in the Workspace. Then it lists the PullRequests of each Repository with `q=reviewers.uuid="..."`.
- The command scans all Repositories. The operator chose no recency filter.
- The output order is Repository slug order, then the Bitbucket order inside each Repository.
- Each row names its Repository by `full_name`. The human row is `full_name#id [STATE draft] title (src -> dst)`.
- The command prints nothing to stdout when any request fails. A 429 fails the command with the existing `RateLimited` error.
- The command rejects bad options before any HTTP request.

## Out of scope

- `--repository`, `--sort`, `--page`, `--pagelen`, and `--no-follow`. The output merges many Repositories, so these flags have no clear meaning.
- Retry or backoff on 429.
- A participant filter.
