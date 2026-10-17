# Bitbucket implementation

The [Bitbucket glossary](./GLOSSARY.md) defines the domain terms used here.

## API quirks

These observations come from live PullRequest checks.

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
