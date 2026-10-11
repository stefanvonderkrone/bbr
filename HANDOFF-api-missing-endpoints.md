# Handoff: missing `bbr api` endpoints

## Request and status

The user asked for all endpoints that `bbr api` supports and all missing endpoints.
The user then asked for this handoff in the project root.
No endpoint implementation was requested.

The current branch has 28 `bbr api` commands that cover 30 distinct REST endpoints.
The Bitbucket Cloud specification lists 294 REST endpoints.
The inventory below contains the remaining 264 endpoints.

These counts describe the source inspected on 2026-10-11.
Each HTTP method and path counts as one endpoint.
Query options do not count as separate endpoints.
Multiple methods on one line represent multiple endpoints.
Missing means that `bbr api` has no command for that operation.
The inventory includes all remaining operations in the specification, including its `/teams` paths.
The inventory does not define a priority or promise implementation of every endpoint.

## Sources and project context

- [Bitbucket Cloud OpenAPI specification](https://api.bitbucket.org/swagger.json).
- [Bitbucket Cloud REST introduction](https://developer.atlassian.com/cloud/bitbucket/rest/intro).
- [`src/api/cli.zig`](src/api/cli.zig): the command table and dispatcher.
- [`src/api/`](src/api/): the command handlers for each resource.
- [`src/bitbucket/client.zig`](src/bitbucket/client.zig): the HTTP adapter and its endpoint tests.
- [`src/bitbucket/CONTEXT.md`](src/bitbucket/CONTEXT.md): the domain terms and API behavior.
- [`CONTEXT-MAP.md`](CONTEXT-MAP.md): the context boundaries.
- [`AGENTS.md`](AGENTS.md): the project instructions.

Bitbucket is the only context that knows HTTP, JSON, and Atlassian's wire vocabulary.
The CLI calls the Bitbucket adapter.
The canonical terms include Workspace, Repository, PullRequest, Comment, Task, Authenticated Account, and Reviewer Verdict.

## Path key

All paths use `https://api.bitbucket.org/2.0`.
The following aliases shorten the endpoint inventory.

```text
R = /repositories/{workspace}/{repo_slug}
P = R/pullrequests/{pull_request_id}
W = /workspaces/{workspace}
J = W/projects/{project_key}
U = /users/{selected_user}
S = /snippets/{workspace}/{encoded_id}
```

The specification uses both `pipelines-config` and `pipelines_config`.
The inventory preserves those spellings.
It also preserves placeholder names, including `pullrequest_id`, `reportId`, and `annotationId`.

## Missing endpoints

### PullRequests and default reviewers

19 endpoints.

```text
GET              R/commit/{commit}/pullrequests
GET              R/default-reviewers
GET, PUT, DELETE R/default-reviewers/{target_username}
GET              R/effective-default-reviewers

POST             R/pullrequests
GET              R/pullrequests/activity
PUT              P
GET              P/activity
GET              P/conflicts
POST             P/decline
GET              P/diffstat
POST             P/merge
GET              P/merge/task-status/{task_id}
GET              P/mergeability/checks
GET              P/patch
GET              P/statuses
GET              W/pullrequests/{selected_user}
```

### Repositories

17 endpoints.

```text
POST, PUT, DELETE R
GET, POST         R/forks
GET, PUT          R/override-settings
GET               R/permissions-config/groups
GET, PUT, DELETE  R/permissions-config/groups/{group_slug}
GET               R/permissions-config/users
GET, PUT, DELETE  R/permissions-config/users/{selected_user_id}
GET               R/watchers
GET               /user/workspaces/{workspace}/permissions/repositories
```

### Commits and comparisons

13 endpoints.

```text
GET              R/commit/{commit}
POST, DELETE     R/commit/{commit}/approve
GET, POST        R/commit/{commit}/comments
GET, PUT, DELETE R/commit/{commit}/comments/{comment_id}
POST             R/commits
POST             R/commits/{revision}
GET              R/diffstat/{spec}
GET              R/file-conflicts/{spec}
GET              R/merge-base/{revspec}
```

### Commit statuses

4 endpoints.

```text
GET      R/commit/{commit}/statuses
POST     R/commit/{commit}/statuses/build
GET, PUT R/commit/{commit}/statuses/build/{key}
```

### Commit reports and annotations

9 endpoints.

```text
GET              R/commit/{commit}/reports
GET, PUT, DELETE R/commit/{commit}/reports/{reportId}
GET, POST        R/commit/{commit}/reports/{reportId}/annotations
GET, PUT, DELETE R/commit/{commit}/reports/{reportId}/annotations/{annotationId}
```

### Branches and tags

9 endpoints.

```text
GET         R/refs
GET, POST   R/refs/branches
GET, DELETE R/refs/branches/{name}
GET, POST   R/refs/tags
GET, DELETE R/refs/tags/{name}
```

### Branch restrictions

5 endpoints.

```text
GET, POST        R/branch-restrictions
GET, PUT, DELETE R/branch-restrictions/{id}
```

### Branching model

7 endpoints.

```text
GET      R/branching-model
GET, PUT R/branching-model/settings
GET      R/effective-branching-model
GET      J/branching-model
GET, PUT J/branching-model/settings
```

### Source and file history

3 endpoints.

```text
GET       R/filehistory/{commit}/{path}
GET, POST R/src
```

### Downloads

4 endpoints.

```text
GET, POST   R/downloads
GET, DELETE R/downloads/{filename}
```

### Deployments, environments, and deploy keys

16 endpoints.

```text
GET, POST        R/deploy-keys
GET, PUT, DELETE R/deploy-keys/{key_id}
GET              R/deployments
GET              R/deployments/{deployment_uuid}
GET, POST        R/environments
GET, DELETE      R/environments/{environment_uuid}
POST             R/environments/{environment_uuid}/changes

GET, POST        J/deploy-keys
GET, DELETE      J/deploy-keys/{key_id}
```

### Pipelines

68 endpoints.

```text
GET, POST        R/deployments_config/environments/{environment_uuid}/variables
PUT, DELETE      R/deployments_config/environments/{environment_uuid}/variables/{variable_uuid}

GET, POST        R/pipelines
GET              R/pipelines/{pipeline_uuid}
GET              R/pipelines/{pipeline_uuid}/steps
GET              R/pipelines/{pipeline_uuid}/steps/{step_uuid}
GET              R/pipelines/{pipeline_uuid}/steps/{step_uuid}/log
GET              R/pipelines/{pipeline_uuid}/steps/{step_uuid}/logs/{log_uuid}
GET              R/pipelines/{pipeline_uuid}/steps/{step_uuid}/test_reports
GET              R/pipelines/{pipeline_uuid}/steps/{step_uuid}/test_reports/test_cases
GET              R/pipelines/{pipeline_uuid}/steps/{step_uuid}/test_reports/test_cases/{test_case_uuid}/test_case_reasons
POST             R/pipelines/{pipeline_uuid}/stopPipeline

GET, DELETE      R/pipelines-config/caches
DELETE           R/pipelines-config/caches/{cache_uuid}
GET              R/pipelines-config/caches/{cache_uuid}/content-uri
GET, POST        R/pipelines-config/runners
GET, PUT, DELETE R/pipelines-config/runners/{runner_uuid}

GET, PUT         R/pipelines_config
PUT              R/pipelines_config/build_number
GET, POST        R/pipelines_config/schedules
GET, PUT, DELETE R/pipelines_config/schedules/{schedule_uuid}
GET              R/pipelines_config/schedules/{schedule_uuid}/executions
GET, PUT, DELETE R/pipelines_config/ssh/key_pair
GET, POST        R/pipelines_config/ssh/known_hosts
GET, PUT, DELETE R/pipelines_config/ssh/known_hosts/{known_host_uuid}
GET, POST        R/pipelines_config/variables
GET, PUT, DELETE R/pipelines_config/variables/{variable_uuid}

GET, POST        /teams/{username}/pipelines_config/variables
GET, PUT, DELETE /teams/{username}/pipelines_config/variables/{variable_uuid}
GET, POST        U/pipelines_config/variables
GET, PUT, DELETE U/pipelines_config/variables/{variable_uuid}

GET              W/pipelines-config/identity/oidc/.well-known/openid-configuration
GET              W/pipelines-config/identity/oidc/keys.json
GET, POST        W/pipelines-config/runners
GET, PUT, DELETE W/pipelines-config/runners/{runner_uuid}
GET, POST        W/pipelines-config/variables
GET, PUT, DELETE W/pipelines-config/variables/{variable_uuid}
```

### Workspaces

9 endpoints.

```text
GET       /user/workspaces/{workspace}/permission
GET       W/members
GET       W/members/{member}
GET       W/permissions
GET       W/permissions/repositories
GET       W/permissions/repositories/{repo_slug}
GET, POST W/projects
GET       W/settings/gpg/public-key
```

### Projects

15 endpoints.

```text
GET, PUT, DELETE J
GET              J/default-reviewers
GET, PUT, DELETE J/default-reviewers/{selected_user}
GET              J/permissions-config/groups
GET, PUT, DELETE J/permissions-config/groups/{group_slug}
GET              J/permissions-config/users
GET, PUT, DELETE J/permissions-config/users/{selected_user_id}
```

### Webhooks

12 endpoints.

```text
GET              /hook_events
GET              /hook_events/{subject_type}
GET, POST        R/hooks
GET, PUT, DELETE R/hooks/{uid}
GET, POST        W/hooks
GET, PUT, DELETE W/hooks/{uid}
```

### Users and email addresses

3 endpoints.

```text
GET /user/emails
GET /user/emails/{email}
GET U
```

### SSH keys

5 endpoints.

```text
GET, POST        U/ssh-keys
GET, PUT, DELETE U/ssh-keys/{key_id}
```

### GPG keys

4 endpoints.

```text
GET, POST   U/gpg-keys
GET, DELETE U/gpg-keys/{fingerprint}
```

### Search

3 endpoints.

```text
GET /teams/{username}/search/code
GET U/search/code
GET W/search/code
```

### App properties

12 endpoints.

```text
GET, PUT, DELETE R/commit/{commit}/properties/{app_key}/{property_name}
GET, PUT, DELETE R/properties/{app_key}/{property_name}
GET, PUT, DELETE R/pullrequests/{pullrequest_id}/properties/{app_key}/{property_name}
GET, PUT, DELETE U/properties/{app_key}/{property_name}
```

### Snippets

24 endpoints.

```text
POST             /snippets
GET, POST        /snippets/{workspace}
GET, PUT, DELETE S
GET, POST        S/comments
GET, PUT, DELETE S/comments/{comment_id}
GET              S/commits
GET              S/commits/{revision}
GET              S/files/{path}
GET, PUT, DELETE S/watch
GET              S/watchers
GET, PUT, DELETE S/{node_id}
GET              S/{node_id}/files/{path}
GET              S/{revision}/diff
GET              S/{revision}/patch
```

### Add-ons

3 endpoints.

```text
PUT, DELETE /addon
GET         /addon/{addon_key}/client-key
```

## Existing coverage that affects the count

The source references above contain the full supported command inventory.
The following details prevent duplicate work:

- `list-commits` covers three endpoints: PullRequest commits, revision commits, and the Repository commit range.
- `get-compare-diff --patch` already covers `GET R/patch/{spec}`.
- `GET P/patch` remains missing.
- `get-blob` and `check-blob` share `GET R/src/{commit}/{path}`.
- `check-blob` uses `?format=meta` and then reads the file bytes. It does not use HEAD.
- `get-verdict` reads `GET P`. It has no separate verdict endpoint.
- `set-verdict` covers POST and DELETE on both `P/approve` and `P/request-changes`.
- `resolve-task`, `reopen-task`, and `update-task` share `PUT P/tasks/{task_id}`.

## Continuation

The next decision is which endpoint group to implement first.
The user did not select a group or request implementation.
No implementation plan, tickets, or code changes exist for this inventory.

Before implementation, check the current command table and the current specification.
Confirm the selected endpoint's request fields, response fields, permissions, and current availability in Atlassian's documentation.
Use the existing command handlers and Bitbucket adapter tests as the starting point.
Follow the local issue tracker instructions in `docs/agents/issue-tracker.md` if the user requests tickets.

## Suggested skills

The next agent can load the following skills when their tasks apply:

- `bbr`: the CLI command rules and the domain terms.
- `implement`: implementation from a selected specification or tickets.
- `ponytail`: minimal code changes.
- `zig`: the repository's Zig version and API rules.
- `technical-writing` and `unslop`: document changes.

## Recheck the specification count

This read-only command counts the published HTTP operations.
It does not calculate current CLI coverage.

```sh
python3 -c 'import json, urllib.request; spec = json.load(urllib.request.urlopen("https://api.bitbucket.org/swagger.json")); methods = {"get", "post", "put", "patch", "delete", "head", "options"}; print(sum(method in methods for path in spec["paths"].values() for method in path))'
```
