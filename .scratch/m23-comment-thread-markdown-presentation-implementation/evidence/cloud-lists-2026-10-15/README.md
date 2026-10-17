# Cloud list observations on 2026-10-15

## Context

The human authorized the agent to author and publish these examples in the agreed test PullRequest.
The agent created one Review-level Comment and one Reply through `bbr api create-comment`.
These are agent-authored live Cloud observations.

- Workspace: `check24`.
- Repository: `pr-webapp`.
- PullRequest: [2425](https://bitbucket.org/check24/pr-webapp/pull-requests/2425).
- Root Comment: [883824183](https://bitbucket.org/check24/pr-webapp/pull-requests/2425/_/diff#comment-883824183).
- Reply: [883824241](https://bitbucket.org/check24/pr-webapp/pull-requests/2425/_/diff#comment-883824241).
- Reply parent: `883824183`.
- Observation date: 2026-10-15.
- Terminal: Ghostty, with Catppuccin Mocha in Ghostty and bbr.
- bbr viewport: 150 columns by 55 rows.

## Captured artifacts

| Artifact | Contents |
| --- | --- |
| [root.md](./root.md) | Exact authored root Markdown, including its ending newline. |
| [reply.md](./reply.md) | Exact authored Reply Markdown, including its ending newline. |
| [root-response.json](./root-response.json) | Selected fields from the root's Cloud single-Comment response. Includes exact `content.raw`, `content.markup`, and `content.html` strings. |
| [reply-response.json](./reply-response.json) | The same response fields for the Reply. |
| [bbr.txt](./bbr.txt) | The two published ReviewCards' displayed text, extracted from the live terminal capture. |

The response artifacts also retain the Comment IDs, parent ID, timestamps, API URLs, and browser links.
They exclude unrelated response fields and authentication headers.
The agent fetched both Comments again and compared the selected response fields with the saved JSON artifacts.
Both comparisons passed.
The agent also compared each `content.raw` value with the corresponding authored file byte for byte.
Both comparisons passed.

## Observed list behavior

| Case | Authored Markdown | Returned Cloud HTML | Observed bbr output |
| --- | --- | --- | --- |
| L01 and L02 | Ordered markers `3.` and `8.`. The first item contains unordered children at four spaces. | `<ol start="3">` with two direct `<li>` children. The first item contains `<ul>` with two children. | Ordered markers `3.` and `4.` with two nested bullets. |
| L03 and L04 | An unordered parent contains ordered markers `7.` and `2.` at four spaces. A second unordered parent follows. | `<ul>` with two direct children. The first contains `<ol start="7">` with two children. | Two parent bullets. Nested ordered markers `7.` and `8.`. |

Both responses use `<strong>`, `<em>`, `<code>`, `<a>`, and `<del>` for the authored inline formatting.
The terminal text capture shows hidden formatting delimiters, complete link destinations, list structure, and Reply indentation.
Human review of the published formatting remains pending.

## Human browser and terminal comparison

The human reported the same parent list structure in the browser and bbr.
The root uses `3.` and `4.` with nested unordered children.
The Reply uses unordered parents L03 and L04 with an ordered child list.
The human confirmed that bbr displays the child markers as `7.` and `8.`.
The human reported that the Bitbucket browser view displays them as `g.` and `h.`.

These markers express the same start value and consecutive item positions.
The captured Cloud HTML uses `<ol start="7">` without a `type` attribute or per-item `value` attributes.
The terminal uses decimal markers, while the browser uses alphabetic markers for this tested nested list.
This observation identifies a presentation difference, not a numbering or nesting difference.
No browser stylesheet or screenshot was captured.

The human also approved bold, italic, inline code, strikethrough, and links in both published examples in the browser.
The corresponding human terminal-style review remains pending.

## Evidence limits

The Cloud HTML establishes first-number preservation and consecutive numbering for these two tested list groups.
The bbr terminal capture agrees with that HTML structure and numbering.
This observation covers only the authored four-space mixed nesting and inline formatting shown here.
It does not establish behavior for other indentation, continuation paragraphs, nested fences, or all Cloud Markdown.
The browser-presentation evidence above is the human's report for these two Comments.
It is separate from the captured Cloud response fields and terminal text.

The human delegated authoring and publication to the agent during this session.
These observations do not change the authorship of the earlier unpublished Draft fixtures.
