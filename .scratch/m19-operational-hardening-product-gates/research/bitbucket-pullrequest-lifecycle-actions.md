# Bitbucket PullRequest lifecycle Actions

Research date: 2026-08-29

This note uses only current Bitbucket Cloud and Atlassian sources. It separates API token scopes from the account's repository permission. Both checks apply.

## Endpoint contracts

All paths start with `https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}`.[^action-contracts]

| Action | Contract | Success | Documented failures | API token scopes |
| --- | --- | --- | --- | --- |
| [Approve][approve-contract] | `POST /approve`; no body | `200` with the authenticated account's `Participant` object | `401`, `404` | `read:pullrequest:bitbucket` and `write:pullrequest:bitbucket` |
| [Unapprove][unapprove-contract] | `DELETE /approve`; no body; removes only the authenticated account's approval | `204` with no body | `400` if already merged, `401`, `404` | `write:pullrequest:bitbucket` |
| [Decline][decline-contract] | `POST /decline`; no body | `200` with the PullRequest | `555` if the operation times out; the contract says to retry later | `read:pullrequest:bitbucket` and `write:pullrequest:bitbucket` |
| [Merge][merge-contract] | `POST /merge`; optional `async` query parameter; JSON body described below | `200` with the PullRequest, or `202` with a polling URL in `Location` | `409` if a ref changes during the merge; `555` on a timeout | `read:pullrequest:bitbucket` and `write:pullrequest:bitbucket` |

The contracts and status descriptions come from the [Pullrequests REST reference][pullrequests] and its linked [canonical OpenAPI document][openapi]. The API token permission reference confirms that pull-request write scope covers approve, decline, and merge, but does not grant repository write scope.[^token-scopes]

The merge body has one required field, `type`. It also accepts `message`, `close_source_branch`, and `merge_strategy`. The documented strategies are `merge_commit`, `squash`, `fast_forward`, `squash_fast_forward`, `rebase_fast_forward`, and `rebase_merge`. The default is `merge_commit`.[^merge-contract] The PullRequest's destination branch reports `merge_strategies` and `default_merge_strategy`, so a client can offer the Repository's configured choices.[^pullrequest-schema]

With `async=true`, merge returns `202` immediately. With `async=false`, merge waits, but can still return `202` when it exceeds the timeout. The client must poll the URL from `Location`. The task endpoint returns `PENDING`, `SUCCESS` with the merged PullRequest, or an error. It documents `400` for a wrong task or failed merge, `403` for task access, and `409` for changed refs.[^merge-task]

## Account permissions

- Anyone with repository read permission or higher can approve.[^approve-permission]
- Unapprove applies only to the authenticated account's approval.[^unapprove-contract]
- The PullRequest author or any reviewer can decline. Decline cannot be undone, does not change either branch, preserves comments and tasks, and stops later branch changes from updating that PullRequest.[^decline-permission]
- Merge requires repository write or admin permission. Branch restrictions and required merge checks can further block merge.[^merge-permission] A `restrict_merges` branch restriction can limit merge to configured accounts and groups.[^branch-restrictions]

An API token remains tied to one account. A correct scope cannot exceed that account's repository permission.[^api-token] For least privilege, these four Actions need pull-request read and write scopes as a set because approve, decline, and merge require both. The endpoints do not require `write:repository:bitbucket`; that scope also does not grant PullRequest API access.[^token-scopes]

## Stale SourceCommit and confirmation controls

The four mutation contracts expose no documented `SourceCommit`, ETag, `If-Match`, dry-run, or confirmation input. The merge `409` protects only against a ref that changes while Bitbucket attempts the merge.[^merge-contract] It does not prove that the loaded `SourceCommit` is still current when an Action starts.

The client must therefore read the current PullRequest before every Action and compare `source.commit.hash` with the loaded `SourceCommit`. If the hashes differ, the client must stop and reload the review. This client check is required for approve, unapprove, and decline as well as merge because none of their contracts accepts a source hash.[^pullrequest-contract]

The API starts each Action in one request. It has no server-side confirmation step.[^action-contracts] The product must own confirmation. Decline needs explicit irreversible-action confirmation. Merge needs confirmation that shows the strategy, commit message, source-branch deletion choice, and current SourceCommit. Approve and unapprove can use direct intent only if the product decision accepts easy reversal before merge.

## Conflicts and recoverable failures

Bitbucket provides `GET /conflicts`, which redirects to a structured file-conflicts result for the PullRequest's current revspec.[^conflicts] Atlassian tells users to resolve merge conflicts locally.[^resolve-conflicts] The merge contract does not document a distinct response for content conflicts. Its only documented `409` means that a ref changed during the merge.[^merge-contract]

Use these recovery rules:

| Result | Recovery |
| --- | --- |
| Approve `200`, unapprove `204`, decline `200`, merge `200` | Accept the returned result. Refresh the PullRequest before the next Action. |
| Merge `202` | Keep the `Location` URL and poll until success or error. Do not submit a second merge while the task is pending. |
| Merge or task `409` | Reload the PullRequest and review because a ref changed. Do not retry from the old Session Epoch. |
| Merge-task `400` | Show the returned error and reload the PullRequest. The contract says this can mean either a wrong task ID or a failed merge. |
| Decline or merge `555` | First read the PullRequest state. Retry only if the intended state did not occur and the current SourceCommit still matches. The API says to retry later, but a timeout does not confirm the final state. |
| Transport failure, `429`, or other server failure | Treat the mutation result as unknown. Reconcile the PullRequest state and authenticated account's participant state before a retry. Never retry decline or merge blindly. |

The PullRequest resource includes its state, source commit, participants, and merge commit. These fields support reconciliation after an uncertain response.[^pullrequest-schema] The endpoint docs do not declare approve, unapprove, decline, or merge idempotent.[^action-contracts]

## Rate limits

These Actions use `/2.0/repositories/*`, so they share the authenticated repository-data pool. Atlassian documents a one-hour rolling window, measured by account ID, with 1,000 requests per hour by default.[^rate-limits] Scaled limits range from 1,000 to 10,000 requests per hour, but require a Standard or Premium Workspace with at least 100 paid accounts and a repository, project, or Workspace access token, or a Forge `asApp` request. A user API token is not listed as eligible for scaled limits.[^rate-limits]

Atlassian says rate limits can change and are not part of the API contract. The documented rate-limit headers apply only to scaled access-token and Forge requests. The page does not document a `Retry-After` guarantee for user API tokens.[^rate-limits] The lifecycle endpoints document no separate limit.

## Product implications

- Treat `SourceCommit` comparison as a mandatory client gate. Bitbucket has no documented optimistic-lock input for these Actions.
- Treat merge as an asynchronous operation even when the client requests synchronous execution.
- Derive merge choices from the destination branch instead of hard-coding one strategy.
- Confirm decline as irreversible. Confirm all merge inputs and effects.
- Reconcile remote state after every uncertain mutation result before any retry.
- Keep API scopes and account permission as separate `ActionAvailability` reasons.

[pullrequests]: https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/
[openapi]: https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json?_v=2.300.189
[approve-contract]: https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-approve-post
[unapprove-contract]: https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-approve-delete
[decline-contract]: https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-decline-post
[merge-contract]: https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-merge-post
[^approve-contract]: [Approve a pull request][approve-contract]
[^unapprove-contract]: [Unapprove a pull request][unapprove-contract]
[^merge-contract]: [Merge a pull request][merge-contract] and the linked [OpenAPI schema][openapi]
[^merge-task]: [Get the merge task status](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-merge-task-status-task-id-get)
[^pullrequest-contract]: [Get a pull request](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-get)
[^pullrequest-schema]: [PullRequest REST schemas and endpoint responses][pullrequests]
[^action-contracts]: [Approve][approve-contract], [unapprove][unapprove-contract], [decline][decline-contract], and [merge][merge-contract] contracts
[^approve-permission]: [Review code in a pull request, "Approve a pull request"](https://support.atlassian.com/bitbucket-cloud/docs/review-code-in-a-pull-request/#Approve-a-pull-request)
[^decline-permission]: [Decline a pull request](https://support.atlassian.com/bitbucket-cloud/docs/decline-a-pull-request/)
[^merge-permission]: [Merge a pull request](https://support.atlassian.com/bitbucket-cloud/docs/merge-a-pull-request/)
[^branch-restrictions]: [Branch restrictions REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-branch-restrictions/)
[^api-token]: [REST API authentication, "API tokens"](https://developer.atlassian.com/cloud/bitbucket/rest/intro/#api-tokens)
[^token-scopes]: [API token permissions, "Pull requests"](https://support.atlassian.com/bitbucket-cloud/docs/api-token-permissions/#Pull-requests)
[^conflicts]: [Get file conflicts for a pull request](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-conflicts-get)
[^resolve-conflicts]: [Resolve merge conflicts](https://support.atlassian.com/bitbucket-cloud/docs/resolve-merge-conflicts/)
[^rate-limits]: [API request limits](https://support.atlassian.com/bitbucket-cloud/docs/api-request-limits/)
