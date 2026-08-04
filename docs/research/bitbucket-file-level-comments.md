# Bitbucket Cloud file-level pull-request comments

Research date: 2026-08-04

## Conclusion

Bitbucket Cloud **natively supports a root pull-request comment scoped to a
changed file without a line coordinate**. It is not a third comment resource or
a new `type`: it is a `pullrequest_comment` whose `inline` object contains
`path`, while `from`, `to`, `start_from`, and `start_to` are absent in a create
request and null in the observed response.

The minimal create shape is therefore:

```json
{
  "content": { "raw": "Comment about the whole file" },
  "inline": { "path": "src/example.zig" }
}
```

This conclusion rests on three independent first-party signals:

1. Atlassian's product documentation says pull requests have three comment
   levels—pull request, individual file, and code line—and directs users to add
   a whole-file comment from the file header.[^ui]
2. Atlassian's REST documentation says comments made on a file or a line have
   an `inline` property.[^rest-activity]
3. The published Swagger schema requires only `path` inside `inline`; every line
   field is optional.[^swagger] A public Atlassian-owned pull request contains a
   concrete root comment with body `File comment`, `inline.path` populated, and
   all four line fields null.[^live-file-comment]

No authenticated request or mutation was performed during this research.

## Wire contract

### Create

Use the ordinary pull-request comment endpoint:

```text
POST /2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments
```

Send `content.raw` plus `inline.path`; omit all line fields. The endpoint accepts
the general `pullrequest_comment` schema and returns the created comment with
HTTP 201.[^rest-create] In the downloaded first-party schema, `inline.required`
is exactly `["path"]`; `from`, `to`, `start_from`, and `start_to` have no
required constraint.[^swagger]

The path should identify a file in the pull request's diff. Atlassian's UI only
offers this action from the header of a changed file, and its resolve endpoint
rejects comments that are not on the diff.[^ui][^rest-resolve]

### Response and identification

There is no explicit `file_level` discriminator. Classify a root comment as:

| Scope | Wire shape on the root |
| --- | --- |
| Pull request | `inline` absent/null |
| File | `inline.path` present and all line/range fields null |
| Line/range | `inline.path` present and at least one line/range field present |

The public first-party example returns:

```json
{
  "type": "pullrequest_comment",
  "parent": null,
  "inline": {
    "path": "packages/editor/conversation/src/components/Editor.tsx",
    "from": null,
    "to": null,
    "start_from": null,
    "start_to": null,
    "outdated": false
  }
}
```

It also returns an HTML link to the comment anchor in the pull-request diff and
a `links.code.href` whose query selects the file path.[^live-file-comment]

### Display

The natural placement is immediately beneath or within the file header, not
beneath a diff line and not in the PR-global section. That mirrors Bitbucket's
own “Add comment” control on the right side of the file header.[^ui]

Bitbucket also exposes these comments through the PR Activity feed and the
Comments dropdown. The latter groups resolved and unresolved comments, and the
UI collapses resolved threads by default.[^ui]

### Threads and replies

A file comment is a normal root comment (`parent` absent). Replies use the same
comment resource and parent relationship as other pull-request comments. The
REST list endpoint explicitly returns global comments, inline comments, and
replies together,[^rest-list] while the UI exposes Reply on comments and says
comments can be viewed inline with a file.[^ui]

The root should remain the source of truth for thread scope. A public line-level
reply demonstrates that Bitbucket may echo the inherited `inline` data on a
reply even though the client creates a reply by parent relationship; this is
supporting evidence for the existing “root owns placement” rule, not proof that
every file-level reply will echo the same fields.[^live-comments]

### Resolve and reopen

File-level threads are resolvable. Atlassian presents Resolve and Reopen as
comment-thread actions across its three comment levels, and documents that
resolved threads collapse in the diff.[^ui] The REST API resolves a top-level
comment with `POST .../comments/{comment_id}/resolve` and reopens it with
`DELETE` on the same URL. It rejects replies and comments not on the diff, which
means callers must pass the file-comment **root** ID.[^rest-resolve]

### Update

Editing uses the ordinary
`PUT .../comments/{comment_id}` endpoint and returns the updated
`pullrequest_comment`.[^rest-update] Atlassian's UI documents editing one's own
comment, but neither the UI nor REST documentation promises that a comment can
be re-anchored between PR, file, or line scopes.[^ui][^rest-update] Treat scope
and path as immutable after creation; send only the updated content unless
future first-party evidence establishes re-anchoring semantics.

## Implications for this repository

The Bitbucket transport is already close to the required contract:

- `review.Anchor` permits a path with every line field null.
- `bitbucket.Client.createComment` already omits null line fields, so an
  `Anchor{ .path = path }` serializes to the native path-only request.
- The response parser already accepts the native path-only `inline` object.

The missing distinction is in domain and presentation semantics. Today,
`Comment.isInline()` and `Thread.isInline()` mean merely “has an anchor,” so
they conflate file-level and line-level comments. The diff buffer only emits
anchored threads while visiting matching lines; a path-only anchor has no line
to match and can disappear from the display. Any implementation should model
the three scopes explicitly (or provide exhaustive predicates), place
file-level roots at their file header, and preserve the root-owned scope for
replies, resolution, filtering, persistence, and ambiguous-POST reconciliation.

This is a product-model and presentation change, but **not** a new Bitbucket
API capability or a new remote comment kind.

## Evidence notes

- The Swagger document was fetched directly from Atlassian on 2026-08-04. Its
  SHA-256 was
  `7e9be973015d29fbfcc05bddf1133f69622428ba54293b98d9c06e55df463a20`.
- The public comment response was read without credentials. It belongs to
  Atlassian's `atlaskit-mk-2` repository, pull request 5695, comment 118571063.
- The observed file comment is stronger than schema inference alone: the body
  calls itself `File comment`, it is a root, and every line coordinate is null.

[^ui]: [Atlassian Support: Review code in a pull request](https://support.atlassian.com/bitbucket-cloud/docs/review-code-in-a-pull-request/)
[^rest-activity]: [Bitbucket Cloud REST API: pull-request activity log](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-activity-get)
[^rest-create]: [Bitbucket Cloud REST API: create a pull-request comment](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-post)
[^rest-list]: [Bitbucket Cloud REST API: list pull-request comments](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-get)
[^rest-resolve]: [Bitbucket Cloud REST API: resolve and reopen a comment thread](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-comment-id-resolve-post)
[^rest-update]: [Bitbucket Cloud REST API: update a pull-request comment](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-comment-id-put)
[^swagger]: [Bitbucket Cloud's published Swagger schema](https://api.bitbucket.org/swagger.json)
[^live-file-comment]: [Public first-party file-comment response](https://api.bitbucket.org/2.0/repositories/atlassian/atlaskit-mk-2/pullrequests/5695/comments/118571063)
[^live-comments]: [Public first-party pull-request comments collection](https://api.bitbucket.org/2.0/repositories/atlassian/atlaskit-mk-2/pullrequests/5695/comments?pagelen=100)
