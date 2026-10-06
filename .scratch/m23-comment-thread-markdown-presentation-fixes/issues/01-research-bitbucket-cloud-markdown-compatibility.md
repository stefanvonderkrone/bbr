# Research Bitbucket Cloud Markdown compatibility

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:research
Type: research
Status: resolved
Assignee: M23 Markdown research session
Research branch: research/m23-cloud-markdown-compatibility

## Question

Which parts of the selected Data Center Markdown guide apply to Bitbucket Cloud PullRequest Comments?

Compare the guide with first-party Cloud documentation and available first-party rendering or API evidence.
Cover headings, paragraphs, emphasis, strikethrough, ordered lists, unordered lists, nested lists, quotes, code, links, images, and tables.
Distinguish CommonMark claims from Cloud-specific parser behavior and Data Center-only extensions.
Distinguish Comment behavior from README behavior.

Investigate list numbering, indentation, mixed nesting, continuation paragraphs, and code blocks inside lists.
Identify the raw Markdown and rendered HTML fields available in the Cloud Comment wire contract.
Collect documented input and output examples that can inform later fixtures.
Label unobserved behavior explicitly. Documentation examples are not live observations.

Record code-fence language identifiers and the limits of any documented syntax-highlighting promise.
Investigate automatic links, Jira references, PullRequest references, HTML handling, and image attributes.
Do not choose terminal approximations or implement a parser.

Link a cited research asset from the answer.

## Answer

Cloud equivalence with the whole selected guide is not established.
Cloud Comment documentation names Python-Markdown with extensions. The Data Center guide names CommonMark with extensions.
The shared documented examples establish broad overlap, not identical edge-case behavior.

Cloud documents ordered and unordered lists, nested lists, fenced code, tables, and strikethrough.
Exact list start numbering and nested-fence behavior remain unobserved for Cloud Comments.
Upstream parser evidence identifies differences that need a project policy or live evidence.
Data Center PullRequest reference forms, image dimensions, and CodeMirror language promises cannot transfer automatically.

The Cloud Comment schema separates `content.raw`, `content.markup`, and `content.html`.
Raw and HTML pairs can support later fixtures, but this research captured no live Comment observations.
The asset separates documented Cloud inputs from upstream output examples and unknown cases.

See [Bitbucket Cloud Comment Markdown compatibility](../research/cloud-markdown-compatibility.md) for the comparison, fixture candidates, and sources.
The same asset is present on `research/m23-cloud-markdown-compatibility` in its temporary worktree.
The worktree is `/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/m23-cloud-markdown-compatibility`.
The research worktree copy is uncommitted.

[Choose Cloud compatibility and evidence policy](./09-choose-cloud-compatibility-and-evidence-policy.md) holds the resulting product decision.
