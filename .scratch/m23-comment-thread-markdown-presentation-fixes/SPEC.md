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
43. As a reviewer, I want temporary Buffer Search disclosure, so that search does not replace my saved disclosure choices.
44. As a reviewer, I want Review Search to save required disclosure, so that an opened result remains visible.
45. As a reviewer, I want generated labels excluded from search, so that search counts reflect authored content.
46. As a reviewer, I want reference destination matches at their visible use, so that navigation reaches readable content.
47. As a reviewer, I want complete displayed emoji highlights, so that partial matches do not split compound emoji.
48. As a reviewer, I want Preview Highlighting priority, so that colors help inspect the current result.
49. As a reviewer, I want authored-path Suggestion colors, so that File changes do not change Grammar selection.
50. As a reviewer, I want required authored delimiters in Selection copies, so that selected blocks retain their Markdown structure.
51. As a reviewer, I want required reference definitions in Selection copies, so that copied destinations retain their authored source.
52. As a reviewer, I want clear yank availability and completion messages, so that I know whether a copy succeeds.
53. As a reviewer, I want stale work rejected, so that an old body cannot change the current presentation.
54. As a reviewer, I want failures to preserve the previous Presentation Frame, so that navigation retains a complete projection.
55. As a LocalReview reviewer, I want the same applicable presentation rules, so that offline discussion remains readable and copyable.

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

### Reply ancestry and width

- Presentation shows each parent before its Replies and completes each Reply subtree before the next sibling.
  Published siblings retain input order and precede Draft siblings in creation order.
  Draft descendants remain inside their parent's subtree.
- A root has depth zero. Each known parent relationship adds one level for published, Draft, and mixed ancestry.
  CommentId and TempId remain distinct owners.
- The available DiffPane width determines the starting indentation unit in terminal columns.
  Widths of at least 100 use four columns per level.
  Widths from 80 through 99 use three. Widths from 60 through 79 use two. Smaller widths use one.
- Each Thread or root Draft subtree uses one unit selected against its deepest known Reply.
  Body disclosure does not remove Replies from that calculation.
  The root body width excludes ordinary ReviewCard padding.
  The indentation budget is the root body width minus the smaller of 40 columns and that width.
  Presentation reduces the starting unit until the deepest Reply fits or the unit reaches one.
  Each ReviewCard's indentation is its depth times that unit, capped at the budget.
- The header, body, and footer use the same offset.
  When the cap hides actual depth, the header identifies the depth.
  At or below 40 root body columns, indentation consumes no body width.
- Deleted Comments retain their place and depth.
  Resolved and Outdated disclosures preserve complete subtree grouping and visibility.
  A ReviewCard body disclosure hides only that body's rows.
- An absent-parent subtree shows `parent unavailable` and preserves known placement and authored parent links.
  Presentation does not invent missing ancestors or CommentScope.
  Depth starts at the highest available ancestor and identifies known relative depth when capped.
  A parent hidden by disclosure is not absent.
- Reconciliation replaces a posted Draft representation once with its fetched Comment.
  Pending Replies follow the posted CommentId without an extra ancestry level.
  ADR-0007 continues to govern transient posted Drafts.

### ReviewBody syntax and styles

- ReviewBody remains width-independent and retains authored source ranges for visible and hidden content.
  ReviewCard projection owns wrapping, generated labels, container offsets, and disclosure.
- Verified Cloud syntax takes precedence over the selected Data Center guide.
  Project decisions define terminal presentation and literal code behavior.
  Unknown Cloud cases use the linked project acceptance examples, not assumed parser equivalence.
- Support ATX and Setext headings, paragraphs, emphasis, strikethrough, lists, quotes, inline code, code blocks, links, and tables.
  Images use a text representation.
  Unsupported syntax remains literal, including Cloud-only extensions outside the chosen guide.
- Valid asterisk and underscore emphasis delimiters hide.
  Intraword underscores remain literal.
  Theme defaults use turquoise for italic text, orange for bold text, and green for inline code.
  Foreground precedence is inline code, bold, italic, then ordinary text.
- Bold, italic, strikethrough, and link underline attributes combine where applicable.
  Inline code keeps its literal content inside emphasis.
  Cursor, Selection, and search backgrounds preserve Markdown foregrounds and attributes.
  Draft ownership does not make the complete body bold.
- Strikethrough uses the terminal attribute when available.
  Otherwise, the authored strikethrough delimiters remain visible.
  Headings show generated `§1` through `§6` markers and bold heading text.
- Paragraphs use one blank row between them.
  Ordinary paragraph line breaks become spaces. Two trailing spaces create a visible hard break.
- Unordered lists use displayed bullets.
  Ordered lists accept digit-plus-period markers and increment from the first authored number.
  Closing-parenthesis markers remain literal.
  Lists require a blank line after preceding prose and between different sibling list types.
- Nested lists use four authored spaces and two displayed spaces per level.
  Ordered and unordered child lists work inside either parent type.
  Wrapped continuation text aligns with item text.
  Each quote level shows a vertical bar. Lists and code retain their rules inside quotes.
- Tables require header and separator rows.
  Separator alignment and inline styles apply to cells.
  Escaped pipes and inline-code pipes do not split cells.
  Missing cells are empty. Rows with extra cells remain literal without discarded text.
  A fitting table uses aligned columns.
  A narrow table projects each row as wrapped, header-labelled cells.
- Explicit links show `label ‹URL›`. Images show `image: alt ‹URL›`.
  Optional titles follow destinations. Complete destinations remain visible through wrapping.
  Relative destinations remain authored text without an inferred base URL.
- Reference links and images resolve within one body through case-insensitive names.
  The first matching definition wins.
  Used definitions hide. Missing references and unused definitions remain literal.
- Bare HTTP and HTTPS URLs link outside code.
  Trailing sentence punctuation and unmatched closing brackets remain outside the destination.
  Product references remain literal.
- Emoji conversion uses the pinned Atlassian standard fixture's exact names and Unicode fallback bytes.
  Matching is case-sensitive and includes the listed compound skin-tone names.
  Conversion applies to visible prose and link labels, including headings, lists, quotes, and table text.
  Code, destinations, escaped names, and unknown names remain literal.
  No inferred aliases, ASCII emoticon conversion, or Unicode normalization applies.
- Escaped punctuation remains literal, and its escape backslash hides.
  Authored HTML tags and entity spellings remain visible text.
  Malformed constructs fall back locally without removing valid formatting elsewhere.
  An unclosed Suggestion must no longer make the complete body literal.

### Literal code and Highlighting

- Support indented code and backtick or tilde fences at the root and inside lists or quotes.
  An opening fence uses at least three matching characters.
  A closing fence uses the same character and at least the opening length.
  Recognized delimiters hide. Unclosed fences remain literal.
- Remove only structural container and code-block indentation.
  Keep code whitespace, Markdown characters, emoji shortcodes, HTML, and language directives literal.
  Wrap long lines without discarding content.
  Inline code also retains literal whitespace.
- Tabs advance to the next multiple of four terminal columns from the code content origin.
  ReviewCard, Reply, list, and quote offsets do not change that origin.
  Stored and copied tabs remain authored bytes.
- Theme code backgrounds are lighter in dark Themes and darker in light Themes.
  Suggestions retain their distinct background and label.
  Plain blocks use the ordinary Theme foreground, not inline-code green.
- A fence's first whitespace-separated information token selects its Grammar identifier without ASCII case sensitivity.
  Later information tokens do not affect Grammar selection or appear as fence labels.
  The [approved alias table](./issues/05-choose-reviewbody-code-block-highlighting.md#fence-identifiers-and-grammarmatch) maps identifiers to representative suffixes through normal GrammarMatch.
  Valid unlisted identifiers supply their normalized extension.
  Such identifiers start with an ASCII letter or digit.
  They contain only ASCII letters, digits, underscores, plus signs, or hyphens.
  Path separators, MIME types, and attribute syntax do not select a Grammar.
- Representative suffixes use synthetic paths without File acquisition.
  Normal UserGrammar precedence and shebang fallback apply.
  Unlabelled fences and ordinary indented code remain plain without Grammar inference.
  A failed UserGrammar permits one matching BuiltInGrammar attempt before plain fallback.
- Suggestions use their root's authored inline File path and replacement code through normal GrammarMatch.
  Replies inherit that context.
  Moved and Outdated Suggestions retain their original authored path.
  Missing context leaves the Suggestion plain without File Enrichment.
- Presentation publishes plain code first and schedules complete-block analysis off the terminal input path.
  Visible ReviewCards make their blocks eligible, including content hidden by body disclosure.
  At most one worker runs.
  Pending work follows displayed ReviewCard order, then authored block order.
  Eligibility uses the current projection without an unbounded queue of copied bodies.
  Started work continues to completion even after its presentation loses eligibility.
- The selected Review Search Preview makes its visible blocks eligible and gives them priority over pending ReviewCard work.
  Changing the result or closing the Overlay removes that Preview's pending eligibility.
  Preview and ReviewCard share accepted results, the worker, and the retained-result budget.
- The existing Highlighting byte limit applies to each complete block after structural indentation removal.
  Its default is 2 MiB. Zero means unlimited. A block exactly at the limit is eligible.
  Oversized blocks remain complete and plain without prefix-only colors.
- Successful results have a fixed 8 MiB Session budget measured by retained allocation capacity.
  The budget excludes authored storage, body metadata, and temporary worker scratch storage.
  Visible Preview blocks count as visible presentations.
  Eviction first removes least recently used results outside visible presentations, then other results as required.
  A result larger than the budget remains plain.
- An evicted successful block can run again after its ReviewCard leaves and re-enters the viewport.
  Eviction does not immediately repeat work while the same ReviewCards remain visible.
  Failed and size-skipped blocks retain bounded state with their body-block identity.
  Only body or Session replacement permits a fresh attempt after failure or size skip.
- Completions carry Session Epoch, authored owner, block, content, and Grammar selection context.
  Presentation rejects stale results and disposes of every completion once.
  Accepted results survive wrapping, disclosure, resize, and Theme changes.
  Theme changes remap Capture roles without another analysis.
- Color admission publishes one complete Presentation Frame.
  Failure preserves the previous complete Frame.
  Colors cannot change text, geometry, ownership, cursor, Selection, or Search Occurrence identity.
  Technical failures use existing diagnostics without repeated status messages.

### Search through ReviewBody

- Both searches match ReviewBody semantic text, not terminal rows or complete raw Markdown.
  Include prose, headings, lists, quotes, table cells, literal code, Suggestion code, labels, destinations, and titles.
  Label and destination regions use equal matching and ranking rules.
- Hidden delimiters, fence metadata, used definitions, and escape backslashes do not participate.
  Generated markers, labels, borders, and disclosure text do not participate.
  Literal fallback and unused definitions remain searchable.
  Repeated narrow table labels do not duplicate an authored header occurrence.
- Ordinary paragraph line breaks join as spaces, including list-item and quote paragraph continuations.
  A matched join space maps to the authored line ending.
  Occurrences retain exact UTF-8 ranges across every matched authored line.
  Blank lines, hard breaks, distinct items, cells, code lines, bodies, and link regions stop matching.
- Buffer Search keeps leftmost, non-overlapping literal matches in semantic corpus order.
  Review Search keeps one best fuzzy match per paragraph region.
  Nonjoined code and source File text remain line-local.
  Terminal wrapping never changes matching boundaries.
- Each converted emoji supplies either its displayed Unicode form or exact authored shortcode form within a match.
  Different emoji can use different forms in one match.
  Shortcode substring queries are valid, but one emoji cannot supply both forms in sequence.
  Authored Unicode does not gain an inferred shortcode.
- Matches through either form map to the complete authored shortcode or compound shortcode range.
  Partial matches highlight the complete displayed emoji.
  Authored locations determine identity, counts, and deduplication.
  Multiple code points or terminal cells do not create additional occurrences.
- Existing smart case, query validation, length limits, simple Unicode folding, and no-normalization rules remain in force.
  M21 fuzzy scores, calculation limits, and deterministic ordering apply to each legal representation.
  Equal representations prefer displayed text, then the earliest authored alignment, then existing corpus order.
- A resolved reference destination participates through each visible use rather than its hidden definition.
  Navigation reaches that use and retains definition ranges separately.
  Result positions identify the first matched authored line and its one-based Unicode scalar column.
- Navigation uses the current Presentation Frame to focus the exact owner and first wrapped row containing the match.
  All projected match parts receive search emphasis.
  Buffer Search temporarily opens required disclosures and restores their saved state.
  Opening a Review Search result saves required disclosure changes after the destination Frame exists.
- Formatted Preview uses the same ReviewBody rules and accepted code colors as ReviewCards.
  Reprojection and color arrival preserve occurrence identity and counts.
  Body changes rebuild relevant matching data. Session replacement clears both searches and expires their occurrences.
  Existing M21 corpus exclusions remain in force, including Deleted Comments.

### Raw yank and Selection ownership

- The existing `y` Action uses an explicit Selection when present.
  Without Selection, any eligible ReviewCard row copies the complete authored body, including hidden content.
  Headers, Suggestion labels, and disclosure footers identify the same owner but add no generated text in complete-body mode.
  Count still copies that body once.
- Unmarked source copying retains logical-Line Count behavior within one File.
  It removes wrapped duplicates and skips interleaved ReviewCards and structural rows.
  Direct invocation on a structural row emits no clipboard command and does not scan ahead.
- Selection copies the inclusive range from top to bottom, regardless of its direction or starting owner.
  Source and ReviewCards retain display order across Files.
  Source rows contribute complete logical Lines from Selected Version.
  Selected body rows contribute complete authored logical lines whose content they display, not the complete paragraph or body.
- Several selected wraps copy a touched line once per typed owner.
  A joined prose row can contribute several authored lines.
  A narrow table cell contributes its complete authored table row.
  Repeated table header labels add no authored header line.
  The actual selected header content contributes its own authored line.
- A selected spacer contributes only its first represented authored blank line with exact whitespace and line ending.
  Generated spacers and marker-only rows contribute nothing.
  Selected ReviewCard headers, disclosure text, and Suggestion labels contribute plain text without terminal markers or indentation.
  Other structural rows contribute nothing.
- A selected displayed reference destination also contributes its use's authored line and resolved definition's authored line.
  The same rule applies to reference images.
  A label-only row does not add a definition whose destination remains unselected.
- Selected block content includes required existing hidden delimiters.
  Valid fenced code and Suggestions include both authored fence lines with metadata and indentation.
  Setext headings include their underline. Tables include their separator line.
  Table content does not imply an unselected header line.
  Indented code adds no fences, and malformed literal delimiters follow the touched-line rule.
- Within each ReviewCard, touched lines and required hidden lines copy in original authored order.
  Deduplication uses CommentId or TempId plus logical line, not displayed text.
  Required definitions and delimiters copy once per owner.
  Selected plain labels retain their display position around body content.
  No unselected code lines, unrelated definitions, intervening blank lines, or invented delimiters enter the copy.
- Every authored contribution comes from raw Review storage.
  Preserve indentation, tabs, trailing spaces, line endings, Markdown markers, and shortcode or Unicode bytes.
  Join separate contributions with a newline only when the preceding contribution has no ending newline.
  Do not add an otherwise absent final newline.
- Selected Version filters source and inline ReviewCards in both layouts through the scope projection that places each ReviewCard.
  Replies inherit the root inline version through published or Draft ancestry.
  Opposite-version inline ReviewCards contribute neither bodies nor selected labels.
  Review-level and File-level ReviewCards remain eligible with either version.
- Bitbucket retains available authored Deleted Comment content.
  Such content is copyable when otherwise eligible, but remains excluded from searches and unavailable for mutation.
  Absent content has no invented replacement.
  Whitespace-only bodies are copyable. Empty bodies emit no complete-body clipboard command.
  Eligible selected plain labels can contribute without a body.
- Every yank invocation consumes Count.
  Count does not limit or repeat a Selection copy.
  Selection clears only after `copy_clipboard` queues owned text.
  Refusal, empty eligible content, and allocation failure preserve Selection.
  A later clipboard failure does not restore it.
  Copying does not change cursor or disclosure state.
- The correlated `clipboard_completed` input reports `copied text` or `could not copy text`.
  Help names the Action `yank text`.
  ActionAvailability and dispatch use the same eligibility rules, with an eligible Selection taking precedence.
  Refused copies emit no command and leave clipboard contents unchanged.

## Testing decisions

The [approved acceptance matrix](./issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-acceptance-matrix) defines the required cases and links their owners.
The [approved test boundaries](./issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-test-boundaries) define their test seams.

- Good tests inspect observable content, source ownership, exact clipboard bytes, navigation, styles, commands, and complete published Frames.
  Tests do not assert private parser storage, cache layout, worker threads, or allocator implementation details.
- Presentation Actions and owned completions are the highest shared integration seam.
  Existing Presentation tests supply prior art for Count, Selection, disclosure, stale work, and allocation-failure rollback.
  Use `dispatch`, `takeCommand`, and the immutable `projection` for shared behavior checks.
  The user approved this seam and the supporting checks in the integrated acceptance answer.
  No new external test seam is required.
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
  Include the current Selected Version yank hardening checks as prior art for refusal and allocation-failure cleanup.
- Highlighting checks inspect eligible work, complete-block limits, result admission, stale completion cleanup, and plain fallback.
  Existing GrammarMatch and Presentation completion tests supply prior art for these checks.
- Bitbucket adapter checks use the existing HttpClient fake and scripted Comment responses.
  Verify available Deleted Comment body retention, absent-body handling, and unchanged structural tombstone behavior.
  Existing paginated Comment and surviving-Reply fixtures supply prior art.
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

The current code supplies ReviewBody authored ranges, ReviewCard ownership, Presentation command handling, headless rendering, and M21 search tests.
The current parser still makes a complete body literal for an unclosed Suggestion.
The current Bitbucket adapter still discards Deleted Comment bodies.
Implementation must replace those behaviors under the approved local-fallback and raw-copy contracts.

[Bitbucket Cloud Comment Markdown compatibility](./research/cloud-markdown-compatibility.md) records the Markdown facts and evidence limits.
[Bitbucket Cloud Comment emoji shortcodes](./research/cloud-emoji-shortcodes.md) records the pinned fixture source, exact fallback examples, and provenance.
Neither research asset contains live Cloud Comment observations.
The later human review supplies the required observed list fixtures.
Selecting its test PullRequest does not block implementation under the agreed project behavior and best-effort policy.
