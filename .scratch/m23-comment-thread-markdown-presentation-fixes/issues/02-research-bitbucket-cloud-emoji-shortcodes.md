# Research Bitbucket Cloud emoji shortcodes

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:research
Type: research
Status: resolved
Assignee: M23 emoji research session
Research branch: research/m23-cloud-emoji-shortcodes

## Question

What first-party evidence defines Bitbucket Cloud Comment emoji shortcode support and its Unicode equivalents?

Identify a usable catalog or documented subset, its provenance, and any license or update constraints.
Include `:white_check_mark:`, aliases, multiple-code-point emoji, and unknown shortcodes.
Investigate escapes, inline code, fenced code, URLs, and case-sensitive shortcode matching.
Separate documented behavior from live observations and unknown behavior.

Determine whether Cloud returns authored shortcodes unchanged in Comment raw content.
Identify evidence needed before bbr can claim complete shortcode compatibility.
Do not choose a catalog size, add a dependency, or implement conversion.

Link a cited research asset from the answer.

## Answer

No authoritative public Cloud Comment emoji catalog was found.
Atlassian's Cloud documentation explicitly says that it has no definitive list of supported emoji.
It documents colon shortcode syntax and `:mask:` as an example.

An Atlassian frontend test fixture maps `:white_check_mark:` to `✅` and contains other Unicode fallbacks.
That fixture supplies a candidate mapping source, not proof of Cloud Comment support or completeness.
The asset records aliases, multiple-code-point examples, source provenance, and reuse terms.

The Comment API defines raw content as the text the user typed, separately from rendered HTML.
Shortcode retention is the documented expectation, but this research captured no live shortcode round trip.
Cloud case, escape, code, URL, alias, and exact Unicode-output rules remain unproven.

See [Bitbucket Cloud Comment emoji shortcodes](../research/cloud-emoji-shortcodes.md) for the evidence and catalog choices.
The same asset is present on `research/m23-cloud-emoji-shortcodes` in its temporary worktree.
The worktree is `/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/m23-cloud-emoji-shortcodes`.
The research worktree copy is uncommitted.

[Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) holds the catalog and conversion-context decision.
