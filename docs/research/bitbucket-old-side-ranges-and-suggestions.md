# Bitbucket old-side ranges and multi-line Suggestions

Research date: 2026-08-08

## Verdict

Bitbucket Cloud's supported inline-coordinate vocabulary is side-specific and
inclusive:

| Authoring case | `inline` request shape |
|---|---|
| old-side single line | `{ "path": P, "from": N }` |
| old-side multi-line range | `{ "path": P, "start_from": TOP, "from": BOTTOM }` |
| new-side single line | `{ "path": P, "to": N }` |
| new-side multi-line range | `{ "path": P, "start_to": TOP, "to": BOTTOM }` |

For every case the comment body is `{ "content": { "raw": BODY } }`. Line
numbers are one-based; a range's `start_*` is its top and its matching
`from`/`to` is its bottom. Send only one side and omit null coordinate fields.

The old-side shapes are safe for ordinary Comments. Bitbucket's current
OpenAPI schema defines them, and retained first-party responses in this
repository show both an old-side single-line Comment and an old-side range.
The latter is `start_from: 13, from: 16` with all new-side coordinates null.

Multi-line Suggestions are proven for new-side ranges. Atlassian's UI guide
explicitly tells a reviewer to drag across multiple lines before choosing
**Suggest code**, enter replacement code in the green/bottom side, and then add
the comment. A Suggestion remains a pull-request Comment at the REST boundary:
the API has no Suggestion object or Suggestion endpoint. Its body is raw
Markdown containing a fenced `suggestion` block.

Old-side Suggestions are **not proven as applicable Suggestions**. The REST
schema permits the same raw string as an ordinary old-side Comment, but
neither the schema nor Atlassian's UI documentation says that the web UI will
render an actionable suggestion or apply it to removed lines. M16 should keep
refusing Suggestion authoring for old-side Anchors. It may allow an ordinary
Comment whose prose happens to contain such a fence only if the product wants
that to degrade to a non-applicable comment; it must not present that as a
Suggestion workflow.

The conservative bbr envelope is therefore:

- allow old-side single- and multi-line **Comments** using the shapes above;
- allow new-side single- and multi-line **Suggestions** using the corresponding
  `to`/`start_to` shape and a fenced `suggestion` body;
- refuse old-side Suggestions, mixed-side coordinates, unmatched `start_*`
  fields, descending ranges, cross-file selections, and selections crossing a
  diff gap;
- do not infer broader support from the OpenAPI example that populates all four
  coordinates at once. Its schema does not describe coordinate combinations or
  their validation rules.

## What the primary sources prove

### REST field semantics

Atlassian identifies `https://api.bitbucket.org/swagger.json` as the canonical,
comprehensive OpenAPI definition for Bitbucket Cloud. In its `comment.inline`
schema:

- `path` is required;
- `from` is the anchor line in the old file and, for a range, its ending line;
- `to` is the anchor line in the new file and, for a range, its ending line;
- `start_from` is the starting line in the old file for a multi-line Comment;
- `start_to` is the starting line in the new file for a multi-line Comment;
- all four coordinates are integers with minimum value 1.

The create operation is
`POST /2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments`
and returns the created Comment with status 201. `content.raw` is the text as
typed by the user. The schema requires only `inline.path` inside an `inline`
object and does **not** express invariants such as one side only,
`start_* <= end`, a maximum range length, or whether both sides may be supplied.
Those omissions are why the generated four-coordinate example is not an
authoring recipe.

The official activity-log example includes an old-side single-line Comment
whose `inline` value has `from: 211` and `to: null`. An unauthenticated read of
that example's public PR on 2026-08-08 likewise returned an old-side Comment
with `from` set and `to` null. This proves the old-side single-line response
shape independently of bbr.

Sources:

- [Bitbucket Cloud REST introduction: OpenAPI is canonical](https://developer.atlassian.com/cloud/bitbucket/rest/intro/#open-api-specification)
- [Canonical Bitbucket Cloud OpenAPI document](https://api.bitbucket.org/swagger.json)
- [Pull-request Comment operations](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-post)
- [Public old-side Comment retained in Atlassian's example PR](https://api.bitbucket.org/2.0/repositories/atlassian/atlaskit-mk-2/pullrequests/5695/comments/118571088)

### Multi-line Comment and Suggestion UI

Atlassian's review guide states that line Comments can span multiple lines by
dragging from the `+` on the first line across the desired lines. Its code
Suggestion procedure uses the same multi-line selection, followed by the
**Suggest code** toolbar action (or `/suggestcode`), editing replacement code
in the green/bottom line, and adding the Comment. Applying a Suggestion is a
separate web-UI action available to the PR author or a repository member with
write permission; applying it creates a commit and refreshes the PR.

This establishes multi-line Suggestion behavior on the new/green side. It does
not say that a reviewer can create or apply one on the old/removed side, nor
does it publish a range-length limit or explain where a multi-line Comment card
is visually attached within the selected range.

The general markup guide says Bitbucket Comments support Python-Markdown's
`fenced_code` extension. It does not define the special `suggestion` info
string; that semantic is documented only by the code-review UI guide and is
not represented in the REST schema.

Sources:

- [Review code in a pull request: line Comments and code Suggestions](https://support.atlassian.com/bitbucket-cloud/docs/review-code-in-a-pull-request/#Add-comments-to-pull-requests)
- [Bitbucket Cloud markup comments](https://support.atlassian.com/bitbucket-cloud/docs/markup-comments/)

## Retained live evidence in this repository

The repository already contains sanitized responses captured from live
Bitbucket Cloud pull requests. They are not a substitute for Atlassian's
published contract, but they are direct first-party observations and close two
otherwise undocumented gaps:

- `src/bitbucket/testdata/comments_pr1726.json` contains an old-side range with
  `start_from: 13`, `from: 16`, and null new-side fields, as well as new-side
  ranges with `start_to` and `to`;
- the same fixture contains new-side Comments whose raw bodies are fenced
  `suggestion` Markdown;
- `src/bitbucket/client.zig` records a PR 1856 probe response for a new-side
  range (`start_to: 67`, `to: 69`), and `TODO.md` records that the PR 1856 live
  probes verified `{start_from, from}` for old-side ranges and
  `{start_to, to}` for new-side ranges.

These captures prove that Bitbucket has returned and retained the side-specific
range shapes. They do not preserve screenshots of how the old-side range was
drawn in the web UI, and the sanitized fixture does not prove the exact POST
validation boundary for malformed or mixed combinations.

Repository pointers:

- [`src/bitbucket/testdata/comments_pr1726.json`](../../src/bitbucket/testdata/comments_pr1726.json)
- [`src/bitbucket/client.zig`](../../src/bitbucket/client.zig)
- [`TODO.md`](../../TODO.md)

## Credential-gated disposable probe still needed

No `BITBUCKET_USERNAME`, `BITBUCKET_TOKEN`, or `BITBUCKET_WORKSPACE` credentials
were present in this research environment. The public Atlassian PR could be
loaded, but its rendered diff could not be inspected through the collaborative
browser. No real PR was mutated.

If M16 needs claims beyond the conservative envelope, run one disposable PR
probe with a file containing unchanged, added, modified, and removed runs. POST
unique, easily deletable Comments and record the status, response `inline`
object, and web-UI screenshot for each of these cases:

1. old-side `{from}` and `{start_from, from}`;
2. new-side `{to}` and `{start_to, to}`;
3. fenced `suggestion` bodies on new-side single- and multi-line ranges;
4. the same fenced bodies on old-side single- and multi-line ranges;
5. deliberately invalid mixed-side, unmatched-start, descending, and
   gap-spanning shapes.

For Suggestions, record whether the body renders as a semantic Suggestion,
whether **Apply suggestion** appears, what exact lines it proposes to replace,
and whether application succeeds. For ranged Comments, record whether the card
is attached to the top, bottom, or whole highlighted range in unified and
side-by-side views. Delete all probe Comments afterward.

Until that probe exists, absence of a documented maximum is not evidence of an
unlimited range, and REST acceptance of raw fenced Markdown is not evidence
that an old-side Suggestion is applicable.
