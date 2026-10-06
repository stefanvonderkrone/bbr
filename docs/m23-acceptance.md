# M23 automated acceptance

This record covers implementation ticket 13, "Verify combined M23 acceptance".
The automated result does not replace the human terminal review in ticket 14.

## Contract and evidence

The approved contract lives in the local issue tracker:

- [Acceptance matrix and test boundaries](../.scratch/m23-comment-thread-markdown-presentation-fixes/issues/08-define-the-integrated-m23-acceptance-contract.md).
- [Selection ownership and exact clipboard bytes](../.scratch/m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md).
- [Human review and Cloud list evidence](../.scratch/m23-comment-thread-markdown-presentation-implementation/issues/14-complete-human-review-and-capture-cloud-list-evidence.md).

The tests define project behavior through the approved observable seams.
They inspect ReviewBody meaning, Buffer projection, terminal cells, Presentation Actions, and owned completions.
Clipboard tests inspect `copy_clipboard` commands and correlated completions.
They do not use the system clipboard.

The fixtures in these tests are project fixtures.
The emoji fixture retains its pinned Atlassian documentation source and exact fallback bytes.
Neither fixture class proves Cloud Comment rendering.
This run captures no Cloud wire, browser presentation, or live bbr presentation observations.
The browser prototypes remain planning examples.
Their colors, fixed emoji widths, hand-built rows, and disclosure budgets do not define application requirements.

## Acceptance coverage

Each row below corresponds to a row in the approved matrix.
The tests from tickets 01 through 12 remain in the hermetic suite.
The new `M23 acceptance` tests check combinations through the same seams.
Test names below are searchable prefixes or complete names in the named files.

| Approved matrix row | Observable checks |
| --- | --- |
| Nested Replies | `buffer.zig`: `M23 ancestry completes mixed parent subtrees`; `M23 acceptance mixed Reply subtrees`. Both Layouts retain parent-grouped published and Draft Replies, typed owners, sibling order, and inherited CommentScope. |
| Narrow Reply indentation | `buffer.zig`: `M23 ancestry shares a width unit`; `M23 acceptance mixed Reply subtrees`. Widths cover both sides of 60, 80, and 100 columns, root body widths below and at 40, and zero indentation budget. `presentation.zig`: `M23 ancestry retains typed cursor` covers resize and capped depth. |
| Deleted Comments, absent parents, disclosure, and Reconciliation | `buffer.zig`: `M23 ancestry labels absent parents`, `reconciles posted Draft aliases`, and `attaches a fetched Reply`. The mixed-subtree tests cover body-only collapse, resolved Threads, and Outdated sections. `presentation.zig`: `M23 yank Deleted Comment content` checks copying, both search exclusions, and mutation refusal. |
| Hidden delimiters and Markdown styles | `review_body.zig`: `M23 inline`. `render.zig`: `M23 inline headless cells` and `M23 acceptance narrow lists`. Every CardRole and built-in Theme retains foregrounds and attributes under Selection, cursor, and search backgrounds. |
| Lists | `review_body.zig`, `review_card.zig`, `search.zig`, and `render.zig`: `M23 containers`. The combined subtree and terminal-cell tests include nested ordered and unordered lists, quotes, links, code, and wrapping. These expectations define project behavior. |
| Added guide formats | `M23 inline`, `M23 links`, and `M23 tables` tests span parsing, projection, search, copying, and rendering. The combined tests include ATX and Setext headings, references, tables, and styled content. |
| Literal code and local fallback | `review_body.zig`: `M23 literal`, `M23 containers keep blank line rules`, and `M23 inline unclosed Suggestion`. `review_card.zig`: `M23 literal code wraps`. `search.zig`: `M23 literal both searches`. `presentation.zig`: `M23 literal yank selected code`. |
| Emoji | `review_body.zig`: `M23 emoji every pinned fixture entry`. `search.zig`: `M23 emoji`. `presentation.zig`: `M23 emoji search navigates exact authored owners`. `render.zig`: `M23 emoji ReviewCards and Preview` and the combined narrow-format test. |
| Code-block Highlighting | `code_highlighting.zig`: `M23 highlighting approved fence aliases`. `presentation.zig`: `M23 highlighting` covers first-token identifiers, GrammarMatch, shebang fallback, authored Suggestion paths, and plain fallback. The native UserGrammar integration remains in the full suite. |
| Highlighting work, limits, and lifetime | `presentation.zig`: `M23 highlighting` covers one worker, size and capacity boundaries, LRU eviction, and retry triggers. `M23 acceptance Highlighting admission failures` checks every admission allocation with active search and Selection. `M23 acceptance Preview priority limits eviction` combines limits, eviction, priority, body replacement, and Session expiry. |
| Both searches through transformed Markdown | `search.zig`: `M23 inline`, `M23 containers`, `M23 links`, `M23 tables`, and `M23 emoji`. These checks cover joined regions, semantic boundaries, generated-text exclusions, mixed emoji forms, deduplication, smart case, and deterministic fuzzy scores. |
| Exact navigation and disclosure | `presentation.zig`: `M23 inline joined search reveals`, `M23 links search navigates reference uses`, `M23 tables search reveals`, and `M23 emoji search navigates`. The existing `M21 hidden Buffer Search` and `M21 authored` tests check publication of destination Frames and disclosure lifetime. The same-Review refresh regression checks Session expiry in both Review modes and Layouts. |
| Formatted Review Search Preview | `render.zig`: Preview tests for inline styles, literal code, containers, links, tables, emoji, and Suggestions. `presentation.zig`: `M23 highlighting selected Preview`, `offscreen Preview shares results`, and `eviction protects only visible Preview blocks`. The combined lifetime test checks priority during active Selection. |
| Raw complete-body yank | `presentation.zig`: `M23 yank copies complete authored bytes from every ReviewCard part`, `accepts Review and File bodies`, and `Deleted Comment content`. These checks include collapsed content, whitespace, tabs, trailing newlines, and Selected Version eligibility. |
| Mixed Selection and source yank | `presentation.zig`: `M23 yank mixed Selection`, `source Count`, `filters root scope`, and `uses LocalReview ScopeProjection`. The combined multi-File test adds fences, Setext underlines, table separators, references, equal CommentId and TempId values, and opposite-version exclusion. |
| Transformed-row extraction | The numbered-example table below identifies the exact-byte checks. The combined extraction tests cover both Layouts, both Selection directions, repeated resize, Count cleanup, and clipboard completion. |
| Authored storage, editing, and Suggestions | `presentation.zig`: `M23 acceptance authored Markdown storage editing and Submission stay byte exact`. Both Review modes retain authored Markdown through search, resize, Composer, External Edit, and store load. Suggestion Composer and External Edit receive replacement code. Remote Submission commands retain both authored bodies and the remapped Reply parent. |
| Combined terminal presentation | `buffer.zig`: `M23 acceptance mixed Reply subtrees`. `render.zig`: `M23 acceptance narrow lists tables links and compound emoji`. Existing syntax-cell tests cover code and Suggestion foregrounds with overlapping backgrounds. All rendering checks use terminal cell measurement rather than prototype widths. |
| Human acceptance | Pending in ticket 14. Automated cell checks do not establish terminal readability, live clipboard delivery, or Cloud rendering. |

All source files in this table live under `src/tui/`.
The new tests use existing files in the test import chain.
`src/main.zig` imports Presentation and the application test chain.
The application chain imports Buffer and rendering tests.

## Numbered clipboard examples

The approved strings retain authored line endings and Markdown bytes.
The tests do not derive expected clipboard bytes from rendered text.

| Example | Exact-byte check in `presentation.zig` |
| --- | --- |
| 1. Joined `first` and `second` | `M23 inline joined prose and Setext yank` covers one wide row and the first narrow row. `M23 acceptance yank completes the numbered` covers both narrow rows and resize. |
| 2. Wrapped `alpha bravo` | The inline test covers the first wrap. The numbered test selects both wraps and deduplicates their authored line. At wide width, that row also touches `charlie delta`, so the current-row rule includes it. |
| 3. Ada table row | The numbered test selects `Ready` alone and then both Ada cells. Both widths copy the authored separator and Ada row once. Neither copies the unselected header or Bo row. |
| 4. Reference destination and label | The numbered test checks the exact `https://example.invalid/` definition. A narrow label-only Selection omits the definition. A wide row includes its displayed destination and definition. |
| 5. Two reference uses | The numbered test checks both authored uses before one definition. `M23 links yank selects reference destinations` also covers reference images, duplicate definitions, CRLF, and unrelated definitions. |
| 6. Compressed blank lines | The inline test checks `"\n"` and `"  \n"`. The numbered test checks `"A\n\nB"`. The touched-line test also covers CRLF and tabs. |
| 7. Fenced code | The numbered test checks the exact one-line and two-line `const x` and `const y` examples. The literal-yank test adds nested containers, metadata, alternate fences, Suggestions, and missing delimiters. |
| 8. Setext heading and generated marker | The inline test checks `"Title\n=====\n"`. `M23 yank Selection ignores generated heading markers` checks refusal for a marker-only row. |
| 9. Search reveal then partial copy | `M23 inline joined search reveals exact rows` checks `"first\n"` after both Buffer Search and Review Search disclosure, in both Review modes and Layouts. |
| 10. Collapsed footer | `M23 yank Selection copies Suggestion and collapsed footer labels` checks only the actual plain footer label. The application label is `"2 hidden rows · 4 total · enter to expand"`. The planning example's `"Show 2 body rows"` names the same label-only rule, not required UI wording. The complete-body test checks no-Selection copying from the footer. |
| 11. Source, Comment, source | `M23 acceptance yank keeps exact source Comment source bytes` checks `"before();\nfirst\nsecond\nafter();"` in both directions, Layouts, and widths. The fixture has an empty author label. Other mixed Selection tests explicitly check selected non-empty plain labels. |

## Regression found during acceptance

Same-Review Session replacement restored navigation from the old Session.
That path could carry a Selection into a fresh Session after its searches expired.
The combined lifetime test exposed the retained Selection.
The smaller refresh test also exposed the retained cursor.

`acceptPreparedSession` now keeps the candidate's initial navigation for every replacement.
This applies the canonical reset from ADR-0012 and the approved M15 state-lifetime contract.
Frame rebuilds within one Session still restore semantic navigation.
Failed Session replacement still preserves the old complete Frame.

## Automated result

Verification uses Zig 0.16.0 on native Apple Silicon macOS with the macOS 15 deployment target.
All checks below passed on 2026-10-06:

- `zig build`.
- `zig build test-m23-acceptance --summary all`. The target runs nine new acceptance tests and three import-root tests.
- `zig test --dep bbr -Mroot=src/tui/buffer.zig -Mbbr=src/root.zig --test-filter "M23 acceptance"`.
- `zig test --dep bbr -Mroot=src/tui/review_body.zig -Mbbr=src/root.zig --test-filter "M23"`. All 26 parser tests passed.
- `zig fmt --check build.zig src tests`.
- `zig build test --summary all`. All 1,086 tests passed across 18 build steps.
- `git diff --check`.

The executable test count increased from 828 to 837.
The core suite ran 239 tests, and the version suite ran 10 tests.
The full suite also passed the version identity, release validation, and native UserGrammar lifecycle checks.
The first full-suite attempt exceeded the tool's 120-second limit during the version identity check.
The completed run used a 600-second tool limit.

## Code review

The review used the starting commit `1ce652b05a13056361d0b92830a024be99bf43f4` as its baseline.
The two review axes inspected the working changes before the commit.

### Standards

The first review found a borrowed Search Occurrence snapshot across dispatch.
The lifetime test now owns a cloned occurrence batch for that comparison.
The review also found format coverage flags that combined several ReviewCards.
The subtree test now checks those flags separately for each typed owner.
The follow-up review found no remaining Standards findings.

### Spec

The Spec review found no missing requirements, scope changes, or incorrect acceptance claims.
The human acceptance work remains in ticket 14.

The targeted checks and the complete 1,086-test suite passed after the review fixes.

## Remaining human work

Ticket 14 owns the required human terminal review.
The human must first agree on the test PullRequest and the Comment authoring scope.
The test PullRequest and scope remain unset.

The human review covers the approved format combinations, narrow Replies, terminal attributes, Themes, disclosure, and clipboard output.
The human must author the example Comments.
The list cases require raw Markdown, returned Cloud HTML, and observed bbr output for the same Comment.
Each observation records its date and Comment context.
Browser presentation observations remain separate from Cloud wire and bbr observations.
Those observations establish only the tested cases.
