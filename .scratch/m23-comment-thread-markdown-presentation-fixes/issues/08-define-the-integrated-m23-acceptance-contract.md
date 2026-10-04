# Define the integrated M23 acceptance contract

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: ready-for-agent
Blocked by: 01, 02, 03, 04, 05, 06, 07, 09, 10, 11

## Question

Do the resolved M23 decisions define a complete, consistent specification ready for implementation?

Combine the decisions into an acceptance matrix without duplicating their detailed answers.
Identify the behavior each original TODO item requires and the guide features the user added.
Link every requirement to its decision ticket and relevant evidence or prototype.

Define the required parser, projection, headless rendering, Presentation, search, and clipboard integration checks.
Separate documented fixtures from observed Cloud wire and browser presentation fixtures.
Apply [Choose Cloud compatibility and evidence policy](./09-choose-cloud-compatibility-and-evidence-policy.md) to all compatibility claims.
Check that unverified list, fence, HTML, and emoji cases have explicit project behavior and acceptance examples.
Include narrow terminals, mixed Reply ancestry, all applicable Themes, literal code, and unknown shortcode preservation.
Include the human example Comment and human review requirement from [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md).
Use that ticket's human review checklist to cover format combinations and interaction backgrounds.
Check the human-confirmed planning examples from [Validate combined Reply and Markdown presentation](./10-validate-combined-reply-and-markdown-presentation.md).

Check that authored storage, editing, Suggestions, disclosure, search locations, and source yank retain their contracts.
Use [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md) for the agreed clipboard contract.
Include mixed Selection, Selected Version filtering, inherited Reply scope, selected labels, hidden logical lines, and available Deleted Comment content.
Confirm that no unresolved scope or behavior decision remains before the specification handoff.
Create new decision tickets for gaps rather than silently choosing answers.
The map can finish only when its remaining in-scope fog is empty.

## Comments

### Integrated acceptance review

The session claimed this ticket after its original dependencies reached `resolved`.
The review found an unresolved Selection source-ownership question.
[Choose Selection source ownership after Markdown projection](./11-choose-selection-source-ownership-after-markdown-projection.md) now blocks this ticket.
This ticket remains open. The matrix below is a proposal, not an answer or a final specification.

### Proposed acceptance matrix

Each row links the decision that owns its detailed behavior.
The checks combine those decisions without making a second copy of their answers.

| Requirement | Decision and evidence | Required check |
| --- | --- | --- |
| Nested Replies from the original M23 milestone | [Choose nested Reply presentation](./03-choose-nested-reply-presentation.md), including its order and width examples | Project published Replies, Draft Replies, and mixed ancestry. Check contiguous subtrees, sibling order, typed owners, and inherited CommentScope. |
| Reply indentation at narrow widths | [Choose nested Reply presentation](./03-choose-nested-reply-presentation.md) and the [accepted combined prototype](../prototype/combined-presentation.html) | Check both sides of every DiffPane width breakpoint. Check root body widths below and at 40 columns, deep capped ancestry, depth labels, and resize. |
| Deleted Comments, absent parents, disclosure, and Reconciliation | [Choose nested Reply presentation](./03-choose-nested-reply-presentation.md) | Check available subtrees, relative depth, resolved and Outdated disclosure, body-only collapse, and one replacement of a posted Draft by its fetched Comment. |
| Hidden formatting delimiters and Markdown colors from the original milestone | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) | Parse supported emphasis and inline code. Inspect semantic ranges and rendered cells for style precedence, attributes, ordinary Draft body weight, and interaction backgrounds. |
| Lists from the original milestone | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) and [Bitbucket Cloud Comment Markdown compatibility](../research/cloud-markdown-compatibility.md) | Check first-number continuation, ordered and unordered nesting, authored and displayed indentation, wrapped continuation text, blank-line boundaries, and literal unsupported markers. Label expected output as project behavior. |
| Guide scope added during planning | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) | Check ATX and Setext headings, paragraph joins and hard breaks, nested quotes, strikethrough, links and titles, reference definitions, image text, and wide and narrow tables. |
| Literal code and local fallback | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) | Check root and container fences, delimiter lengths, unclosed fences, indented code, tabs, wrapped code, directives, HTML, entities, and malformed constructs beside valid formatted prose. Earlier valid content must retain its formatting. |
| Emoji from the original milestone | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) and [Bitbucket Cloud Comment emoji shortcodes](../research/cloud-emoji-shortcodes.md) | Check exact pinned fixture names and fallback bytes. Include selectors, flags, compound skin tones, and joiner sequences. Check unknown names, case, escaped names, literal code, and unchanged destinations. |
| Code-block Highlighting | [Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md) | Check aliases, first-token selection, normal GrammarMatch and shebang fallback, UserGrammar precedence, authored Suggestion paths, missing context, and complete plain fallback. |
| Highlighting work, limits, and lifetime | [Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md) and [ADR-0012](../../../docs/adr/0012-presentation-is-a-typed-command-producing-state-machine.md) | Dispatch typed commands and completions. Check one active worker, complete-block size boundaries, the retained allocation-capacity budget, eviction, retry triggers, stale-result disposal, and atomic publication failures. |
| Both searches through transformed Markdown | [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) | Check joined-paragraph matches, semantic boundaries, mixed emoji forms, authored-location deduplication, smart case, deterministic fuzzy ranking, equal label and destination support, and generated-text exclusion. |
| Exact search navigation and disclosure | [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) | Check complete authored ranges, first matched position, complete emoji highlights, reference-use navigation, temporary Buffer Search reveals, saved Review Search disclosures, reprojection, and Session expiry. |
| Formatted Review Search Preview | [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) and the [accepted combined prototype](../prototype/combined-presentation.html) | Check shared ReviewBody formatting and code results. Check selected Preview priority, removal of pending eligibility, shared result storage, plain-first presentation, and unchanged geometry after colors arrive. |
| Raw complete-body yank from the original milestone | [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md) | Inspect exact `copy_clipboard` bytes from every eligible ReviewCard part. Include collapsed content, whitespace-only bodies, fences, tabs, trailing newlines, and available Deleted Comment content. |
| Mixed Selection and source yank | [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md) | Check both Selection directions, multiple owners and Files, wrapped-line deduplication, permitted selected labels, excluded structural rows, Selected Version and inherited scope, Count, Selection cleanup, refusals, and clipboard completions. Add transformed-row cases after the source-ownership decision. |
| Authored storage, editing, and Suggestions | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md), [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md), and [Choose ReviewBody code-block Highlighting](./05-choose-reviewbody-code-block-highlighting.md) | Compare stored, Composer, External Edit, and emitted submission bodies with authored bytes. Check Suggestion recognition, replacement content, inherited inline context, and existing mutation restrictions. |
| Combined terminal presentation | [Validate combined Reply and Markdown presentation](./10-validate-combined-reply-and-markdown-presentation.md) | Repeat the accepted combinations in actual parser, projection, and rendering checks. Do not treat the prototype's fixed emoji width, colors, or disclosure budget as application requirements. |
| Human acceptance after implementation | [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md#human-review-checklist) | A human authors the example Comments in an agreed test PullRequest. A human reviews the complete format-combination checklist in bbr, including narrow Replies, code colors, clipboard output, terminal attributes, and light, dark, and system Themes. |

### Proposed test boundaries

- Parser checks inspect width-independent ReviewBody meaning and authored source ranges.
  They include local fallback and byte-preserving literal content.
- Projection checks inspect ReviewCard order, width, wrapping, disclosure, typed owners, and source mapping.
  They cover Unified and SideBySide layouts and RemoteReview and LocalReview where the behavior applies.
- Headless rendering checks inspect cell text, terminal-column boundaries, foregrounds, backgrounds, and attributes.
  Style checks cover every built-in Theme and applicable ReviewCard role.
  Combined scenarios cover cursor, Selection, and search backgrounds without changing existing Action availability.
- Presentation integration checks dispatch Actions and owned completions through the existing seam.
  They inspect exact navigation, clipboard text, work scheduling, stale-work cleanup, and preservation of the previous complete Frame on failure.
- The complete hermetic test suite must pass with `zig build test --summary all` during implementation acceptance.
  New test files must participate in the test import chain.
  This planning session does not run application acceptance checks for unimplemented behavior.
- The post-implementation human review remains required.
  The browser prototype does not replace that review.

### Evidence classes

Use [Choose Cloud compatibility and evidence policy](./09-choose-cloud-compatibility-and-evidence-policy.md) for every compatibility statement.

- Project fixtures define expected bbr behavior from the decision tickets.
  They do not prove Cloud renderer behavior.
- Documentation fixtures retain their cited product, source, and example context.
  Upstream parser output and README examples are not observed Cloud Comment output.
- The emoji fixture retains its pinned Atlassian source and exact fallback bytes.
  It is not a complete Cloud catalog.
- Observed Cloud wire fixtures pair raw Markdown and returned HTML for the same Comment.
  They record the observation date and relevant context.
- Observed browser presentation and observed bbr presentation remain separate evidence.
  Neither substitutes for a wire capture.

The research assets contain no live Cloud Comment observations.
The original M23 list item requests observed wire and presentation fixtures.
The compatibility policy permits implementation before live proof when the specification states explicit project behavior.
Final acceptance requires raw Markdown, returned Cloud HTML, and observed bbr output for the human-authored list examples.
Capture those fixtures during the post-implementation human review in the agreed test PullRequest.
These fixtures establish the tested cases, not complete Cloud compatibility.
No test PullRequest location is agreed in this session.

### Existing contracts and handoff blockers

[Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) changes M21's authored matching units and Preview behavior.
It retains the existing search corpus exclusions, including Deleted Comments, from [M21 Buffer and Review Search](../../m21-buffer-review-search/SPEC.md).
Available Deleted Comment content becomes copyable under the yank decision.
That change does not by itself make Deleted Comments searchable or mutable.

The current ReviewBody parser makes the complete body literal for an unclosed Suggestion.
The Markdown decision instead requires local fallback for the affected construct.
Implementation acceptance must check that change explicitly.

One matter prevents resolution:

- [Choose Selection source ownership after Markdown projection](./11-choose-selection-source-ownership-after-markdown-projection.md) must define exact clipboard extraction for transformed rows.

The implementation-ready specification can follow only after this acceptance review and its blocking decision resolve.

### Human confirmation of observed fixtures

The user accepted the recommended final acceptance requirement with "ok".
Require raw Markdown, returned Cloud HTML, and observed bbr output for human-authored list examples.
Capture the fixtures during the post-implementation human review.
This confirmation does not approve the complete acceptance matrix or resolve the Selection source-ownership question.

Release the claim while [Choose Selection source ownership after Markdown projection](./11-choose-selection-source-ownership-after-markdown-projection.md) blocks this ticket.
The ticket remains open and cannot return to the frontier until that decision resolves.
