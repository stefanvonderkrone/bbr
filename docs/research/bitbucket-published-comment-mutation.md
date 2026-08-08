# Bitbucket Cloud published comment mutation contract

Research date: 2026-08-08

## Decision summary

For Bitbucket Cloud pull requests, treat every published root comment and reply as the same server-owned `pullrequest_comment` resource, addressed by its comment ID. An authenticated author may edit the body's `content.raw` with `PUT` and may request deletion with `DELETE`. Determine authorship by comparing the authenticated account's `uuid` from `GET /2.0/user` with the comment's `user.uuid`; do not compare display names or configured email/username strings.

Treat a published inline anchor as immutable. Bitbucket documents creation-time and response-time inline fields, but does not document moving an existing comment to a different path or line. Re-anchoring therefore means creating a new comment and, when safe, deleting the old one—not sending `inline` in an update.

Code suggestions are comments in the first-party UI, so an author-owned suggestion-bearing comment is eligible for the same body edit operation. However, the REST contract exposes no suggestion-specific field or syntax. The client should round-trip and replace only the server-provided `content.raw`; it must not promise that it can synthesize, structurally modify, or preserve an unrecognized suggestion representation without an integration probe.

Deleting a pull-request root comment that has replies is the one unresolved server-behavior gap. The pull-request endpoint does not document whether it tombstones the root, cascades, or rejects. The shared comment schema has `deleted` and `parent`, and the analogous Bitbucket Cloud commit-comment endpoint explicitly tombstones a deleted parent while retaining visible replies, but Atlassian does not state that rule for pull-request comments. Product behavior must therefore never locally cascade-delete replies: issue the root delete, then reconcile from Bitbucket and render whatever surviving parent/replies the server returns.

## Contract by question

### Authenticated author identification

1. Call `GET /2.0/user` using the same credential that will perform the mutation. Atlassian defines this as returning the currently logged-in account. The returned Account schema includes `uuid`. [Users REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-users/#api-user-get)
2. Pull-request comments use the shared Comment schema. Its `user` property is an Account, and Account includes `uuid`. [Bitbucket Cloud OpenAPI: Comment and Account schemas](https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json?_v=2.300.184)
3. Enable author-only edit/delete when `current_user.uuid == comment.user.uuid`. Cache the current UUID for the authenticated session, but refresh it after credentials change.

`display_name` is presentation data, not an identity key. The configured login email or legacy username is also not the comment-author key exposed by this API. Repository, project, and workspace access tokens are represented by Bitbucket as users in the UI and API, so the same server-returned identity comparison is preferable for token-authored comments. [Bitbucket Cloud authentication reference](https://developer.atlassian.com/cloud/bitbucket/rest/intro/#access-tokens)

If `GET /user` is unavailable under the credential's scopes, the client does not have a documented substitute that safely proves authorship. It should leave mutation actions disabled rather than infer ownership from display text.

### Edit and delete root comments and replies

`GET /repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments` explicitly includes global comments, inline comments, and replies. A reply is represented by the same Comment schema with a `parent` comment. [Pull requests REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-get)

Both roots and replies are therefore mutated by their own IDs at the same endpoint:

```text
PUT    /2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments/{comment_id}
DELETE /2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments/{comment_id}
```

For an edit, send the narrow body:

```json
{
  "content": { "raw": "replacement body" }
}
```

The documented success response is `200` with the updated comment; `403` means the authenticated principal lacks access to update it, and `404` means it does not exist. For deletion, success is `204`; the endpoint also documents `403` and `404`. The resolve/reopen operations explicitly reject non-top-level comments, while update/delete have no such restriction, reinforcing that replies use update/delete by their own IDs. [Pull requests REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-comment-id-put)

Atlassian's first-party review UI states that a user can edit only their own comments. The REST reference's `403` descriptions are less specific ("does not have access"), so the server remains authoritative even after the UUID preflight. [Review code in a pull request](https://support.atlassian.com/bitbucket-cloud/docs/review-code-in-a-pull-request/#Collaborate-on-code-and-provide-feedback)

### Suggestion-bearing bodies

Atlassian documents a code suggestion as content added through a pull-request comment and exposes the ordinary Edit action for one's own comments. [Review code in a pull request](https://support.atlassian.com/bitbucket-cloud/docs/review-code-in-a-pull-request/#Add-a-code-suggestion)

The current OpenAPI has no suggestion object or suggestion field in `pullrequest_comment`; the only body representation is the shared `content` object (`raw`, `markup`, and rendered `html`). [Bitbucket Cloud OpenAPI: `pullrequest_comment` and `comment`](https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json?_v=2.300.184)

Consequences for the client:

- An author-owned suggestion-bearing comment may use the normal `content.raw` edit endpoint.
- Prefill from the exact `content.raw` returned by Bitbucket and submit only the replacement `content.raw`.
- Do not reconstruct the body from rendered HTML.
- Do not model a separate suggestion mutation endpoint; none is documented.
- Until a disposable-repository integration probe records the actual raw suggestion representation and round-trip behavior, label suggestion preservation as server-dependent and verify the reconciled response after each edit.

### Root deletion and replies

The pull-request DELETE documentation says only that it deletes a specific comment and returns `204`; it does not describe the effect on replies. Atlassian's UI documentation says the comment is removed from the pull request and Activity, but likewise says nothing about a populated thread. [Pull requests REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-comment-id-delete), [Review code in a pull request](https://support.atlassian.com/bitbucket-cloud/docs/review-code-in-a-pull-request/#Collaborate-on-code-and-provide-feedback)

The analogous commit-comment DELETE endpoint, built on the same shared Comment schema, is explicit: a deleted comment with visible replies remains as a resource, has `deleted: true`, has its content blanked, and continues to appear in collection and self responses so the tree remains intact. [Commits REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-commits/#api-repositories-workspace-repo-slug-commit-commit-comments-comment-id-delete)

That commit behavior is evidence for the safest pull-request client policy, not proof of the pull-request endpoint's behavior. On a successful root DELETE, preserve local descendants until a follow-up list/get reconciles them. Never infer that `204` authorizes a local subtree cascade.

### Published inline anchor mutation

The shared Comment schema defines `inline.path`, `from`, `to`, `start_from`, and `start_to`, and the pull-request update request is typed broadly as a `pullrequest_comment`. However, the update prose only promises to update a comment's contents; it gives no semantics for changing the inline location. The analogous commit-comment update is explicit that only comment content can be updated. Neither Atlassian's REST docs nor its first-party review UI documents a "move comment" operation. [Pull requests REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-comment-id-put), [Commits REST reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-commits/#api-repositories-workspace-repo-slug-commit-commit-comments-comment-id-put), [Bitbucket Cloud OpenAPI: Comment schema](https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json?_v=2.300.184)

Accordingly, the supported contract is content mutation only. Keep the published anchor from the server response immutable in local state. If a user wants a different anchor, create a replacement inline comment and then offer deletion of the original. If the original has replies, warn that the discussion cannot be atomically moved and do not silently reparent replies.

## Evidence gaps and required probe

Primary documentation does not settle three details:

1. whether pull-request root deletion with replies uses the same tombstone rule documented for commit comments;
2. the exact `content.raw` representation of a code suggestion and whether arbitrary edits preserve its suggestion behavior; and
3. whether a pull-request `PUT` silently ignores or actively rejects supplied `inline` changes.

A disposable private repository can close these gaps with one root comment, one reply, and one suggestion comment. The probe should record sanitized request/response shapes and post-mutation GET/list results. Until then, the safe product contract is: UUID-gated actions, body-only PUT, ID-specific DELETE, immutable anchors, and mandatory reconciliation after every mutation.
