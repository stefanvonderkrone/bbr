# Bitbucket

Anti-corruption layer over the Bitbucket **Cloud** REST API (`api.bitbucket.org/2.0`).
The only context that speaks HTTP, JSON, and Atlassian's wire vocabulary; it translates
that vocabulary into our domain terms so nothing else depends on Atlassian's shape.

## Language

**Workspace**:
The account that owns repositories (ours is `check24`). The `{workspace}` path segment in every API call.
_Avoid_: org, team, project.

**Repository**:
A git repository within a Workspace, addressed by its slug.
_Avoid_: repo slug (that's just the identifier), project.

**PullRequest**:
A proposed set of changes from a source branch to a destination branch, identified by a `PullRequestId` (integer, unique per Repository). The aggregate root a review is about.
_Avoid_: PR (fine in prose, not as a type name), merge request, changeset.

**SourceCommit**:
The head commit hash of the PR's source branch at the moment we loaded it. Captured so we can detect that the PR "moved under us" before submitting.
_Avoid_: head, tip, revision.

**RawDiff**:
The unified-diff text returned by the diff endpoint. The authoritative input to the Diff context — never rendered directly.
_Avoid_: patch, diff text.

**ApiError**:
A classified failure from an API call, distinct from a transport error: `network`, `rate_limited`, `server`, `unauthorized`, `forbidden`, `bad_request`, `not_found`, `conflict`. The classification, not the raw status code, drives retry/abort/continue decisions.
_Avoid_: HTTP error, status, exception.

**Credential**:
The Atlassian account email plus API token used for HTTP Basic auth, read from the environment. Never logged, never persisted.
_Avoid_: password, app password, secret, key.

## API quirks (verified against live PRs)

**Outdated comments.** The comments *list* endpoint
(`/pullrequests/{id}/comments`) does **not** include `inline.outdated` — only
the *single-comment* endpoint (`.../comments/{cid}`) does, and `?fields=` cannot
force it into the list. Outdated status also can't be recomputed from line
numbers: a stale comment's anchor line may still exist in the current diff (PR
1726 comment 811927613 anchors new-line 38, which is inside a current hunk, yet
Bitbucket marks it outdated). What *does* distinguish them: each comment's
`links.code.href` embeds the diff revision it was anchored to
(`.../diff/{ws}/{repo}:{src}..{dst}?path=…`). A comment is **current** iff that
`{src}..{dst}` equals the PR's current `source.commit`/`destination.commit`;
otherwise **outdated**. We derive it that way — authoritative (Bitbucket's own
commit metadata, per ADR-0001) and free (no per-comment fetch). Hashes may be
abbreviated on one side, so compare by prefix.
