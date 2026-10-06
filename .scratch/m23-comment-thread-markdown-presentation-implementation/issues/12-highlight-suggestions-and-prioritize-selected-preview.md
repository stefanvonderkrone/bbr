# 12 — Highlight Suggestions and prioritize selected Preview

**What to build:** Use the authored inline File context to color Suggestion replacement code. Give visible code in the selected Review Search Preview priority through the same bounded Highlighting system.

**Blocked by:** 05 — Present and search joined paragraphs and headings. 11 — Highlight fenced code with bounded background work.

**Status:** resolved

- [x] A recognized Suggestion uses its root's authored inline File path and replacement code through normal GrammarMatch. Replies inherit that root context.
- [x] Moved and Outdated Suggestions retain the original authored path. Missing context leaves the Suggestion plain.
- [x] Do not use the cursor File, infer a replacement path, acquire File content, or wait for File Enrichment.
- [x] Suggestions retain their distinct background and label under syntax colors and plain fallback.
- [x] The selected Preview makes its visible code blocks eligible even when the corresponding ReviewCard is outside the viewport or collapsed.
- [x] Pending Preview work precedes pending ReviewCard work. Preserve authored block order within the Preview.
- [x] Changing the selected result or closing the Overlay removes that Preview's pending eligibility. Already-started work continues to completion.
- [x] Preview and ReviewCards share accepted block results, one worker, the complete-block byte limit, and the 8 MiB retained-capacity budget.
- [x] Visible Preview blocks count as visible presentations for result use and eviction. Do not analyze every search result or add a separate Preview budget.
- [x] Preview uses the same ReviewBody formatting, code backgrounds, literal content, and Grammar fallback as ReviewCards.
- [x] Show complete plain Preview code before colors arrive. Search backgrounds preserve Markdown attributes and syntax foregrounds.
- [x] Theme, wrapping, disclosure, and resize reuse results. Color arrival changes no text, geometry, ownership, cursor, Selection, or Search Occurrence identity.
- [x] Reject stale completions after Session, body, or Grammar context changes. Preserve the previous complete Frame on admission failure.
- [x] Verify authored path retention after rename, inherited Reply context, absent context, Preview priority, shared-result reuse, and Overlay eligibility removal.
- [x] Cover RemoteReview and LocalReview where applicable. Run `zig build test --summary all`.

## Contract

Use the [approved Suggestion context](../../m23-comment-thread-markdown-presentation-fixes/issues/05-choose-reviewbody-code-block-highlighting.md#suggestions) and the [formatted Preview and priority contract](../../m23-comment-thread-markdown-presentation-fixes/issues/06-choose-search-through-markdown-projection.md#formatted-preview-and-code-block-highlighting).

## Verification

The tests use the agreed Presentation dispatch, Highlighter command, and terminal-cell rendering seams.
The LocalReview test checks the inherited authored path after a rename.
The RemoteReview tests check outdated published Replies, Draft Replies to published Replies, and absent inline context.
The Preview tests check priority, offscreen eligibility, result reuse, selection changes, Overlay closure, and block-level eviction.
The terminal-cell test checks plain Suggestion code before colors arrive and syntax foregrounds under search backgrounds in every Theme.
The yank test also checks that Suggestion Highlighting preserves the cursor and disclosure.

Checks passed on native macOS with the macOS 15 deployment target:

- `zig build`
- `zig build test-code-highlighting --summary all`. All 28 tests passed.
- `zig build test-yank --summary all`. All 36 tests passed.
- `zig test --dep bbr -Mroot=src/tui/code_highlighting.zig -Mbbr=src/root.zig --test-filter "M23 highlighting"`
- `zig fmt --check build.zig src tests`
- `zig build test --summary all`. All 1,077 tests passed across 18 build steps.
- `git diff --check`

The Standards and Spec review found no remaining findings in the changes against `90736b7`.
