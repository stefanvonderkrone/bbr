# 13 — Verify combined M23 acceptance

**What to build:** Verify that Reply ancestry, Markdown, search, Highlighting, and copying work together through the approved acceptance matrix. Fix gaps that appear only when those features combine.

**Blocked by:** 01 — Show actual Reply ancestry. 07 — Present nested lists and quotes. 08 — Present links, references, and image text. 09 — Present tables at wide and narrow widths. 10 — Convert and search emoji shortcodes. 12 — Highlight Suggestions and prioritize selected Preview.

**Status:** resolved

- [x] Cover every row of the approved M23 acceptance matrix through its existing observable test seam. Each preceding ticket retains its own acceptance tests.
- [x] Exercise parent-grouped mixed Replies with headings, styles, links, emoji, lists, quotes, code, Suggestions, and tables at narrow widths.
- [x] Check both sides of every Reply width breakpoint, zero indentation budget, capped depth labels, body disclosure, and resize.
- [x] Cover Unified and SideBySide layouts, all applicable ReviewCard roles and built-in Themes, and RemoteReview and LocalReview where applicable.
- [x] Verify Markdown and code foregrounds and attributes under cursor, Selection, and search backgrounds, including overlapping backgrounds.
- [x] Check generated-text exclusions, joined-paragraph boundaries, reference-use navigation, full compound-emoji emphasis, and stable occurrence identity.
- [x] Check temporary Buffer Search disclosure and saved Review Search disclosure with exact destination Frame publication.
- [x] Verify every numbered exact clipboard-byte example from the Selection ownership answer.
- [x] Combine required fences, Setext underlines, table separators, and reference definitions with multiple selected owners and source Files.
- [x] Verify typed-owner deduplication, authored order within cards, selected plain labels, Selected Version exclusion, Count, and clipboard completion behavior.
- [x] Keep available Deleted Comment content copyable but excluded from both searches and unavailable for mutation.
- [x] Confirm that ordinary Composer and External Edit receive authored Markdown. Suggestion Composer retains its replacement-code contract.
- [x] Verify unchanged authored storage and Submission bytes through observable operations.
- [x] Combine Highlighting limits, eviction, Preview priority, stale completion disposal, body replacement, and Session expiry with active interaction state.
- [x] Inject allocation failures into relevant shared Actions and completion admission. Failures preserve the previous complete Frame and dispose of owned work once.
- [x] Treat prototype colors, fixed emoji widths, hand-built rows, and illustrative disclosure budgets as planning examples rather than application requirements.
- [x] Keep project fixtures, documentation fixtures, Cloud wire observations, browser observations, and bbr observations distinct.
- [x] New test files participate in the test import chain. The complete hermetic suite passes with `zig build test --summary all`.
- [x] Record the automated acceptance result and any remaining human-review work without claiming that automated checks replace terminal readability review.

## Contract

Use the [approved acceptance matrix](../../m23-comment-thread-markdown-presentation-fixes/issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-acceptance-matrix), [test boundaries](../../m23-comment-thread-markdown-presentation-fixes/issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-test-boundaries), and [exact clipboard-byte examples](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples).
The final answer approves those historically titled proposal sections. Ticket 14 owns the required post-implementation human review.

## Verification

[M23 automated acceptance](../../../docs/m23-acceptance.md) maps every approved matrix row and numbered clipboard example to its observable tests.
Nine new acceptance tests cover combined formats, typed owners, exact bytes, Highlighting lifetime, allocation failures, and authored storage.
They use existing files in the test import chain.

The combined tests found old navigation and Selection after same-Review Session replacement.
The fix keeps the candidate's initial navigation, as ADR-0012 and the approved M15 state-lifetime contract require.
The targeted tests failed before the fix and passed after it.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig build`.
- `zig build test-m23-acceptance --summary all`. All 12 tests passed, including three import-root tests.
- The single-file Buffer acceptance test and all 26 M23 ReviewBody parser tests.
- `zig fmt --check build.zig src tests`.
- `zig build test --summary all`. All 1,086 tests passed across 18 build steps.
- `git diff --check`.

The first full-suite attempt exceeded the 120-second tool limit during version identity checks.
The completed run used a 600-second tool limit.
Ticket 14 remains ready for human review.
Its test PullRequest and authoring scope remain unset.

The Standards review found two test issues.
The fixes own the Search Occurrence snapshot across dispatch and check format coverage separately for each typed owner.
The follow-up Standards review found no remaining findings.
The Spec review found no findings.
The complete 1,086-test suite passed again after those fixes.
