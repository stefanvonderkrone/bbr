# 13 — Verify combined M23 acceptance

**What to build:** Verify that Reply ancestry, Markdown, search, Highlighting, and copying work together through the approved acceptance matrix. Fix gaps that appear only when those features combine.

**Blocked by:** 01 — Show actual Reply ancestry. 07 — Present nested lists and quotes. 08 — Present links, references, and image text. 09 — Present tables at wide and narrow widths. 10 — Convert and search emoji shortcodes. 12 — Highlight Suggestions and prioritize selected Preview.

**Status:** ready-for-agent

- [ ] Cover every row of the approved M23 acceptance matrix through its existing observable test seam. Each preceding ticket retains its own acceptance tests.
- [ ] Exercise parent-grouped mixed Replies with headings, styles, links, emoji, lists, quotes, code, Suggestions, and tables at narrow widths.
- [ ] Check both sides of every Reply width breakpoint, zero indentation budget, capped depth labels, body disclosure, and resize.
- [ ] Cover Unified and SideBySide layouts, all applicable ReviewCard roles and built-in Themes, and RemoteReview and LocalReview where applicable.
- [ ] Verify Markdown and code foregrounds and attributes under cursor, Selection, and search backgrounds, including overlapping backgrounds.
- [ ] Check generated-text exclusions, joined-paragraph boundaries, reference-use navigation, full compound-emoji emphasis, and stable occurrence identity.
- [ ] Check temporary Buffer Search disclosure and saved Review Search disclosure with exact destination Frame publication.
- [ ] Verify every numbered exact clipboard-byte example from the Selection ownership answer.
- [ ] Combine required fences, Setext underlines, table separators, and reference definitions with multiple selected owners and source Files.
- [ ] Verify typed-owner deduplication, authored order within cards, selected plain labels, Selected Version exclusion, Count, and clipboard completion behavior.
- [ ] Keep available Deleted Comment content copyable but excluded from both searches and unavailable for mutation.
- [ ] Confirm that ordinary Composer and External Edit receive authored Markdown. Suggestion Composer retains its replacement-code contract.
- [ ] Verify unchanged authored storage and Submission bytes through observable operations.
- [ ] Combine Highlighting limits, eviction, Preview priority, stale completion disposal, body replacement, and Session expiry with active interaction state.
- [ ] Inject allocation failures into relevant shared Actions and completion admission. Failures preserve the previous complete Frame and dispose of owned work once.
- [ ] Treat prototype colors, fixed emoji widths, hand-built rows, and illustrative disclosure budgets as planning examples rather than application requirements.
- [ ] Keep project fixtures, documentation fixtures, Cloud wire observations, browser observations, and bbr observations distinct.
- [ ] New test files participate in the test import chain. The complete hermetic suite passes with `zig build test --summary all`.
- [ ] Record the automated acceptance result and any remaining human-review work without claiming that automated checks replace terminal readability review.

## Contract

Use the [approved acceptance matrix](../../m23-comment-thread-markdown-presentation-fixes/issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-acceptance-matrix), [test boundaries](../../m23-comment-thread-markdown-presentation-fixes/issues/08-define-the-integrated-m23-acceptance-contract.md#proposed-test-boundaries), and [exact clipboard-byte examples](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#exact-clipboard-byte-examples).
The final answer approves those historically titled proposal sections. Ticket 14 owns the required post-implementation human review.
