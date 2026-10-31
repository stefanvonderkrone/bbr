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
bbr api list-workspace-pull-requests --author UUID [--reviewer UUID]
    [--state OPEN|MERGED|DECLINED|SUPERSEDED]... [--query Q] [--limit N] [--json]

bbr api list-workspace-pull-requests (--author UUID | --reviewer UUID | --author UUID --reviewer UUID)
    --repository SLUG... [--concurrency N] [--state OPEN|MERGED|DECLINED|SUPERSEDED]...
    [--query Q] [--limit N] [--json]
```

- `--author` and `--reviewer` each take one account UUID. The command needs at least one of them.
- `--repository` repeats. Each value names one Repository to scan. Without `--repository`, the command needs `--author`.
- `--state` repeats. The default is `OPEN`. Without a `q` filter, each value becomes one `state=` parameter. With a `q` filter, the states go into `q`, because Bitbucket then ignores `state=`.
- `--query` is a Bitbucket `q` expression. The command joins it to its own filter with `AND (...)`.
- `--limit` caps the total number of PullRequests in the output.
- `--concurrency` sets the number of parallel Repository requests. Only the `--repository` scan sends parallel requests, so `--concurrency` without `--repository` is an option error. The default and the CPU cap follow `search-workspace-members`.

## Behavior

- Without `--repository`, the command follows the pages of the author endpoint. A `--reviewer` value becomes `reviewers.uuid="..."` in `q`.
- Without `--repository`, the output keeps the Bitbucket order of the author endpoint, and paging stops at `--limit`. The page size is `--limit` up to 50. Sorting by Repository would need every page first. A live call with two states and `--limit 5` took 19 s with sorting and 1 to 2 s without it.
- With `--repository`, the command lists the PullRequests of each named Repository. Its `q` holds the states, `author.uuid="..."` for `--author`, `reviewers.uuid="..."` for `--reviewer`, and the `--query` expression, joined with AND.
- With `--repository`, the output order is the order of the `--repository` values, then the Bitbucket order inside each Repository. A repeated slug is scanned once, at its first position.
- `--reviewer` without `--repository` fails before any HTTP request, and the help says that the reviewer scan needs `--repository`.
- Each row names its Repository by `full_name`. The human row is `full_name#id [STATE draft] title (src -> dst)`.
- The command prints nothing to stdout when any request fails. A 429 fails the command with the existing `RateLimited` error.
- The command rejects bad options before any HTTP request.

## Decisions

- The operator decided that a reviewer scan names its Repositories. An earlier version listed every Repository in the Workspace when only `--reviewer` was given. The check24 Workspace has 553 Repositories, so one run sent about 560 requests. Bitbucket allows 1,000 requests an hour, and live runs failed with HTTP 429.

## Out of scope

- `--sort`, `--page`, `--pagelen`, and `--no-follow`. The output merges many Repositories, so these flags have no clear meaning.
- A scan of every Repository in the Workspace.
- Retry or backoff on 429.
- A participant filter.
