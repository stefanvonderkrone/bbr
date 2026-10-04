# M23 Comment thread and Markdown presentation fixes

Status: ready-for-agent
Milestone: M23
Map: [M23 Comment thread and Markdown presentation fixes](./map.md)

## Problem statement

Reviewers need readable Comment bodies and clear Reply ancestry while they inspect a Diff.
Flat Reply presentation hides parent relationships.
Visible Markdown delimiters, missing emoji conversion, and limited list presentation make authored discussion harder to read.
Formatted bodies also require precise search locations and raw Markdown copying.

The selected Markdown guide describes Data Center, but bbr uses Bitbucket Cloud.
The guide and Cloud documentation do not establish identical parser behavior or a complete Cloud emoji catalog.

## Solution

Present actual known Reply ancestry and formatted ReviewBody content without changing authored Comment or Draft bytes.
Use Theme-based Markdown styles, text-only images, literal code, and best-effort emoji mappings.
Reuse Highlighting for eligible code blocks and the selected Review Search Preview.
Both searches find semantic prose and converted emoji through exact authored locations.
The existing `y` Action copies complete raw bodies or eligible mixed Selection content.

The resolved decision answers define the detailed behavior.
This specification is their implementation handoff.
The approved acceptance contract combines their requirements and checks.

## User stories

1. As a reviewer, I want actual Reply ancestry, so that I can identify each Reply's parent.
2. As a reviewer, I want contiguous parent subtrees, so that related Replies stay together.
3. As a reviewer, I want published and Draft Replies together, so that I can inspect the complete discussion.
4. As a reviewer, I want readable narrow Replies, so that indentation does not consume their body width.
5. As a reviewer, I want depth labels when indentation caps, so that deep ancestry remains clear.
6. As a reviewer, I want Deleted Comments to retain their place, so that surviving Replies keep their ancestry.
7. As a reviewer, I want absent parents identified, so that missing ancestry does not look like a known root.
8. As a reviewer, I want Reconciliation to avoid duplicate parents, so that each published Comment appears once.
9. As a reviewer, I want Markdown delimiters hidden, so that valid formatting reads as text.
10. As a reviewer, I want Theme-based emphasis colors, so that bold, italic, and inline code remain distinct.
11. As a reviewer, I want combined styles preserved, so that nested formatting keeps its meaning.
12. As a reviewer, I want ordinary Draft body weight, so that Draft ownership does not mask authored emphasis.
13. As a reviewer, I want heading levels identified, so that Comment structure remains clear.
14. As a reviewer, I want paragraphs and hard breaks distinguished, so that prose keeps its intended structure.
15. As a reviewer, I want nested lists and aligned continuations, so that list hierarchy remains readable.
16. As a reviewer, I want nested quotes identified, so that quoted text stays distinct from surrounding prose.
17. As a reviewer, I want wide and narrow tables, so that terminal width does not discard cell content.
18. As a reviewer, I want complete link destinations, so that I can inspect where links point.
19. As a reviewer, I want body-local references resolved, so that reference links display their destinations.
20. As a reviewer, I want image text and destinations, so that images retain useful context in the terminal.
21. As a reviewer, I want known emoji shortcodes displayed as emoji, so that authored prose reads naturally.
22. As a reviewer, I want unknown shortcodes preserved, so that unsupported names do not lose their content.
23. As a reviewer, I want literal code content, so that Markdown and emoji rules do not change code.
24. As a reviewer, I want wrapped code and visible tabs, so that narrow presentation does not discard code bytes.
25. As a reviewer, I want distinct code backgrounds, so that code stays separate from prose.
26. As a reviewer, I want code syntax colors where available, so that familiar Grammar rules help me read code.
27. As a reviewer, I want readable plain fallback, so that unavailable Highlighting does not hide code.
28. As a reviewer, I want responsive input during Highlighting, so that code analysis does not block navigation.
29. As a reviewer, I want local literal fallback, so that one malformed construct does not remove valid formatting elsewhere.
30. As a reviewer, I want both searches to find joined prose, so that visible paragraph phrases remain searchable.
31. As a reviewer, I want emoji and shortcode queries, so that either representation finds the same authored location.
32. As a reviewer, I want exact search navigation, so that results focus the correct owner and matched text.
33. As a reviewer, I want formatted Search Preview, so that the Preview reflects ReviewBody presentation.
34. As a reviewer, I want stable matches after resize, so that wrapping does not change search counts or identity.
35. As a reviewer, I want complete raw-body copying, so that clipboard output retains authored Markdown and whitespace.
36. As a reviewer, I want mixed Selection copying, so that source and discussion copy together in displayed order.
37. As a reviewer, I want exact transformed-row extraction, so that selected content copies its agreed authored lines.
38. As a reviewer, I want Selected Version filtering, so that clipboard output excludes opposite-version inline content.
39. As a reviewer, I want available Deleted Comment content copyable, so that deletion does not discard readable evidence.
40. As a reviewer, I want unchanged editing and Submission bytes, so that presentation does not rewrite authored content.
41. As a reviewer, I want human-reviewed format combinations, so that automated checks do not replace terminal readability review.
42. As a reviewer, I want observed Cloud list fixtures, so that compatibility claims have evidence for their tested cases.

## Implementation decisions

The linked answers are authoritative.
Earlier proposals in ticket comments are history unless the final answer explicitly adopts them.
The later Selection source-ownership answer refines the earlier yank answer.

| Contract | Owning decision |
| --- | --- |
| Reply traversal, sibling order, depth, width policy, structural cases, and Reconciliation | [Choose nested Reply presentation](./issues/03-choose-nested-reply-presentation.md#answer) |
| Supported Markdown syntax, Theme composition, structural presentation, code whitespace, links, image text, emoji, and local fallback | [Choose ReviewBody Markdown presentation](./issues/04-choose-reviewbody-markdown-presentation.md#answer) |
| Grammar selection, Suggestion context, code-block work, limits, result lifetime, and fallback | [Choose ReviewBody code-block Highlighting](./issues/05-choose-reviewbody-code-block-highlighting.md#answer) |
| Semantic search corpus, paragraph joins, emoji forms, ranking, authored locations, navigation, and formatted Preview | [Choose search through Markdown projection](./issues/06-choose-search-through-markdown-projection.md#answer) |
| Complete-body and mixed Selection copying, Selected Version, Deleted Comments, Count, completion, and Action availability | [Choose raw ReviewBody yank behavior](./issues/07-choose-raw-reviewbody-yank-behavior.md#answer) |
| Source precedence, supported scope, best-effort claims, and evidence requirements | [Choose Cloud compatibility and evidence policy](./issues/09-choose-cloud-compatibility-and-evidence-policy.md#answer) |
| Acceptance of combined Reply and Markdown presentation | [Validate combined Reply and Markdown presentation](./issues/10-validate-combined-reply-and-markdown-presentation.md#answer) |
| Touched-line extraction, required hidden lines, exact bytes, and authored order within each ReviewCard | [Choose Selection source ownership after Markdown projection](./issues/11-choose-selection-source-ownership-after-markdown-projection.md#answer) |
| Combined acceptance matrix, test boundaries, evidence classes, and final human review | [Define the integrated M23 acceptance contract](./issues/08-define-the-integrated-m23-acceptance-contract.md#answer) |

Responsibility follows the existing context boundaries:

- Review owns exact authored content, typed Comment and Draft identities, parentage, and CommentScope.
- Presentation owns ReviewBody semantics, ReviewCard projection, source mapping, search integration, Selection extraction, and Theme composition.
- Highlighting supplies code foreground Spans through existing Highlighter and GrammarMatch behavior.
- Bitbucket preserves available authored Deleted Comment content rather than discarding it because of deletion.
- Worker and clipboard effects use the existing typed Presentation command and completion boundary.
  [ADR-0012](../../docs/adr/0012-presentation-is-a-typed-command-producing-state-machine.md) governs ownership and atomic publication.

[M21 Buffer and Review Search](../m21-buffer-review-search/SPEC.md) remains the existing search contract outside the explicit M23 changes.
Those changes include semantic paragraph matching, emoji representations, formatted Preview, and ReviewBody search style composition.
Existing corpus exclusions remain in force.
Available Deleted Comment content is copyable but remains excluded from both searches and unavailable for mutation.
Ordinary Composer and External Edit receive authored Markdown.
Suggestion Composer retains its existing replacement-code contract.

No new runtime dependency, Grammar, timeout setting, or clipboard backend is required by the approved decisions.

## Testing decisions

The [approved acceptance matrix](./issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-acceptance-matrix) defines the required cases and links their owners.
The [approved test boundaries](./issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-test-boundaries) define their test seams.

- Good tests inspect observable content, source ownership, exact clipboard bytes, navigation, styles, commands, and complete published Frames.
- Presentation Actions and owned completions are the highest shared integration seam.
  Existing Presentation tests supply prior art for Count, Selection, disclosure, stale work, and allocation-failure rollback.
- Pure ReviewBody checks inspect semantic ranges, parsing, and local literal fallback.
  Existing ReviewBody tests supply prior art for emphasis, links, Suggestions, and authored ownership.
- Projection checks inspect Reply ordering, narrow widths, wrapping, disclosure, and transformed-row source mapping.
  Existing Buffer and Frame tests supply prior art for Unified and SideBySide layouts and exact row ownership.
- Headless rendering checks inspect cell text, column boundaries, Theme foregrounds, backgrounds, and terminal attributes.
  Existing render and Theme checks supply prior art for ReviewCard roles and search styling.
- Search checks inspect joined paragraph regions, legal emoji forms, semantic boundaries, deterministic ranking, and exact authored navigation.
  Existing M21 kernel and Presentation tests supply prior art for query validation, occurrence identity, disclosure, and Session expiry.
- Clipboard checks inspect `copy_clipboard` text and correlated completions through Presentation.
  The [exact-byte Selection examples](./issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples) are required acceptance cases.
- Highlighting checks inspect eligible work, complete-block limits, result admission, stale completion cleanup, and plain fallback.
  Existing GrammarMatch and Presentation completion tests supply prior art for these checks.
- Checks cover all applicable built-in Themes, ReviewCard roles, both layouts, and RemoteReview and LocalReview where applicable.
- Implementation acceptance requires the complete hermetic suite to pass with `zig build test --summary all`.
  New test files participate in the test import chain.

The accepted [combined presentation prototype](./prototype/combined-presentation.html) and [Selection examples](./prototype/selection-copy-questions.html) are planning assets.
Their fixed colors, emoji widths, hand-built rows, and illustrative disclosure limits are not application requirements.

Final acceptance also requires post-implementation human review:

- A human agrees on the test PullRequest and authoring scope before authoring example Comments.
- A human reviews the [format-combination checklist](./issues/04-choose-reviewbody-markdown-presentation.md#human-review-checklist) in bbr.
- The review captures raw Markdown, returned Cloud HTML, and observed bbr output for the human-authored list examples.
- Evidence follows the [approved evidence classes](./issues/08-define-the-integrated-m23-acceptance-contract.md#evidence-classes) and Cloud compatibility policy.
  Project fixtures and upstream examples do not become Cloud observations.
  Observed browser presentation remains distinct from Cloud wire evidence and observed bbr output.

## Out of scope

- Bitbucket Server or Data Center transport support.
- Complete Cloud Markdown or emoji equivalence.
- Cloud-only syntax extensions excluded by the compatibility decision.
- Product reference navigation and previews. M31 owns that investigation.
- Image acquisition and terminal image rendering. M32 owns that investigation.
- Additional shipped Grammars or a new syntax-color system.
- Changes to authored Comment or Draft bytes merely to match their presentation.
- Changes to CommentScope, Anchor authority, Submission policy, or mutation restrictions.
- Other milestones, including the Repository Browser and durable File Read State.

## Further notes

The user approved the integrated acceptance contract and closure of the map with `ok`.
All planning tickets are resolved, and no in-scope fog remains.
This specification is ready for implementation. The application does not yet implement this specification.

[Bitbucket Cloud Comment Markdown compatibility](./research/cloud-markdown-compatibility.md) records the Markdown facts and evidence limits.
[Bitbucket Cloud Comment emoji shortcodes](./research/cloud-emoji-shortcodes.md) records the pinned fixture source, exact fallback examples, and provenance.
Neither research asset contains live Cloud Comment observations.
The later human review supplies the required observed list fixtures.
Selecting its test PullRequest does not block implementation under the agreed project behavior and best-effort policy.
