# Bitbucket implementation

The [Bitbucket glossary](./GLOSSARY.md) defines the domain terms used here.

## API quirks

These observations come from live PullRequest checks.

### PullRequest states and q

A PullRequest list ignores the `state` parameter when the request also has a `q` parameter.
This applies to `/repositories/{ws}/{repo}/pullrequests` and to `/workspaces/{ws}/pullrequests/{user}`.
Live checks on Repository `pr-reise-cockpit` showed this behavior:

- `state=OPEN` with `q=reviewers.uuid="{uuid}"` returned MERGED PullRequests.
- The same request with `q=reviewers.uuid="{uuid}" AND state="OPEN"` returned no PullRequests.
- `state=OPEN` with `q=source.branch.name="PCO-89-fe-login-für-internen-cockpit-adm"` returned the MERGED PullRequest 146.
  The TUI uses this request to find the AdjacentPullRequest.
- The author endpoint without `q` returned only DECLINED PullRequests for `state=DECLINED`.

`pullRequestListUrl` in `client.zig` builds every PullRequest list URL.
Without a `q` filter, it sends one `state` parameter for each state.
With a `q` filter, it puts the states into `q`, for example `(state="OPEN" OR state="MERGED") AND reviewers.uuid="{uuid}"`.
A live check returned the same PullRequests for `state=DECLINED&state=OPEN` and for `q=(state="DECLINED" OR state="OPEN") AND (id > 0)`.

### Outdated Comments

The Comments list endpoint, `/pullrequests/{id}/comments`, omits `inline.outdated`.
Only the single-Comment endpoint, `.../comments/{cid}`, returns it.
The `?fields=` parameter cannot add it to the list response.

Line numbers alone do not establish Outdated status.
PullRequest 1726 Comment 811927613 anchors new-line 38 inside a current Hunk, but Bitbucket marks it Outdated.
Each Comment's `links.code.href` contains its authored diff revision as `.../diff/{ws}/{repo}:{src}..{dst}?path=…`.
The Comment is current when `{src}..{dst}` matches the PullRequest's current `source.commit` and `destination.commit`.
Otherwise, it is Outdated.
The adapter uses this commit metadata without a per-Comment fetch, as specified by ADR-0001.
Hashes can use abbreviated forms on one side, so the adapter compares them by prefix.

### Mixed-side ranges

Bitbucket can return old-file `from` and `start_from` fields alongside new-file `to` and `start_to` fields for one inline range.
The adapter selects the new-file projection.
The Review context defines an Anchor as single-sided and renders context Lines on the new side when available.

### Account mentions

Bitbucket stores a mention as `@{ACCOUNT_ID}`. The identifier is an Atlassian account ID, not a Bitbucket UUID.
`GET /2.0/users/{user_id}` accepts either identifier and returns the public profile.
`bbr api get-user --user-id ID --json` exposes the account ID, UUID, display name, and nickname.
The Workspace Member commands currently return UUIDs and names, but omit account IDs.
Keep the authored mention unchanged when a lookup fails or when saving the Comment.
Remote Session loading resolves each distinct prose mention once through `getUser`.
The Session keeps the display label as `@Display Name`, with the nickname as a fallback.
A failed lookup keeps the authored token visible and does not fail the Session.
Code, escaped mentions, and link destinations do not cause lookups.
ReviewCards, both searches, and Review Search previews use the same Session labels.
Drafts use labels already acquired for that Session. A new account ID stays literal until a remote Comment supplies it.
Selection, editing, and Submission keep the authored account ID, not the display label.

Sources: [Atlassian's mention API guide](https://support.atlassian.com/bitbucket-cloud/kb/how-to-mention-users-in-pull-request-comments-through-the-bitbucket-cloud-rest-api/) and a live account-ID and UUID lookup.

### Emoji metadata

Atlassian's Bitbucket serializer can emit `:pray:{: data-emoji-id='1f64f' data-emoji-text='🙏' }`.
The suffix belongs to the preceding emoji. It is not visible prose or a second emoji.
For this example, ReviewBody shows one `🙏` and hides the recognized suffix.
It consumes a suffix only when its Unicode ID matches the preceding catalog emoji.
The optional text attribute must also match that emoji.
Unknown attributes, custom IDs, malformed metadata, and text inside code stay unchanged.
The emoji's authored range includes the suffix, so Selection keeps the original bytes.
Both searches accept the emoji and its shortcode, but exclude the consumed metadata.

Source: the [emoji serializer in `@atlaskit/editor-bitbucket-transformer` 10.2.3](https://unpkg.com/@atlaskit/editor-bitbucket-transformer@10.2.3/dist/esm/serializer.js).
