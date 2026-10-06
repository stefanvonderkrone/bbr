# 11 — Highlight fenced code with bounded background work

**What to build:** Show plain fenced code immediately, then add available syntax colors without blocking terminal input. Bound retained results and preserve a complete usable Frame after failures or stale work.

**Blocked by:** 06 — Present literal code blocks and Suggestions.

**Status:** resolved

- [x] Select a fence Grammar from its first whitespace-separated information token without ASCII case sensitivity. Later tokens affect neither selection nor visible fence labels.
- [x] Use the approved alias-to-suffix table through normal GrammarMatch and synthetic paths without File acquisition.
- [x] Valid unlisted identifiers supply their normalized extension. Require an ASCII letter or digit first, then only letters, digits, underscores, plus signs, or hyphens.
- [x] Reject paths, MIME types, and attribute syntax for Grammar selection. Keep their complete recognized code presentation plain.
- [x] Preserve normal UserGrammar precedence and shebang fallback. A failed UserGrammar permits one matching BuiltInGrammar attempt before plain fallback.
- [x] Keep unlabelled fences and ordinary indented code plain without Grammar inference. Add no runtime dependency or shipped Grammar.
- [x] Publish plain code first. Run complete-block analysis off the terminal input path through typed commands and owned completions.
- [x] A visible ReviewCard makes all its blocks eligible, including code hidden by body disclosure. Run at most one code-block worker.
- [x] Choose pending work in displayed card order, then authored block order. Recompute eligibility from the current projection without an unbounded copied-body queue.
- [x] Skip work that loses eligibility before launch. Let started work finish even after its card leaves the viewport.
- [x] Apply the existing Highlighting byte limit to each complete block after structural indentation removal. Exactly-at-limit blocks qualify. Zero means unlimited.
- [x] Oversized blocks retain complete plain content without prefix-only colors. Add no timeout or new setting.
- [x] Keep a fixed 8 MiB Session budget for successful retained results, measured by allocation capacity.
- [x] Exclude authored storage, body metadata, and temporary worker scratch storage from that budget. Release worker scratch storage after analysis.
- [x] Evict least recently used results outside visible presentations first, then other results as needed. A result larger than the budget remains plain without a repeated analysis loop.
- [x] Permit an evicted successful block to run again after its card leaves and re-enters the viewport. Do not repeat it immediately.
- [x] Keep bounded failure and size-skip state with body-block identity. Only body or Session replacement permits a fresh attempt.
- [x] Correlate completions with Session Epoch, typed owner, block, content, and Grammar context. Dispose of accepted or rejected owned completions exactly once.
- [x] Retain accepted results across wrapping, resize, disclosure, and Theme changes. Theme changes remap Capture roles without new analysis.
- [x] Admit colors through one complete Presentation Frame. Failure preserves the previous Frame, text, geometry, ownership, cursor, Selection, and occurrence identity.
- [x] Use existing diagnostics for technical failures without repeated status messages. Plain fallback uses ordinary foreground and the agreed code background.
- [x] Verify observable scheduling, Grammar fallback, byte boundaries, capacity budget, eviction, retry triggers, stale work, launch failure, and admission rollback.
- [x] Run `zig build test --summary all`.

## Contract

Use the [approved Highlighting answer](../../m23-comment-thread-markdown-presentation-fixes/issues/05-choose-reviewbody-code-block-highlighting.md#answer), including its exact alias table and acceptance examples.
ADR-0012 governs commands, completions, and publication. The existing Highlighter supplies foreground Spans.
Ticket 12 adds Suggestion context and selected Preview eligibility to this same worker and budget.

## Implementation

ReviewBody retains the first fence information token as body metadata.
The code-block worker supplies the approved synthetic paths to the existing Highlighter.
Normal GrammarMatch, UserGrammar precedence, and BuiltInGrammar fallback remain the selection path.

Presentation selects complete blocks when their ReviewCard enters the viewport.
It selects work directly when the adapter drains commands, so pending blocks need no copied-body queue.
One owned command carries the complete code and authored source mapping to the worker.
The worker releases its command and scratch storage after analysis.
Owned completions carry the Session Epoch, typed owner, block, content, and Grammar context.

Session-owned block metadata retains failures, size skips, and eviction retry state.
Successful results use exact-sized source Span allocations.
The 8 MiB budget also counts the allocation capacity of Frame annotations.
Admission stages all annotation allocations before eviction and publication.
Colors enter the complete Frame without rebuilding text, geometry, navigation, or search mappings.
Mouse press and release targets also survive color admission.

## Verification

The approved seams cover ReviewBody, Presentation commands and completions, and headless rendering.
The checks include every approved alias, structural byte limits, offscreen eligibility, hidden blocks, and one-worker scheduling.
They also cover retained capacity, eviction order, viewport retry, replacement, deletion, launch failure, admission failure, and closed-sink cleanup.
Real Highlighter results reach `drawReview` through a published Frame.
Rendering checks cover wrapping, tabs, cursor, Selection, search, and every built-in Theme.
RemoteReview and LocalReview checks verify reuse across layout and disclosure changes.
The complete suite includes the existing UserGrammar precedence and failure-fallback checks.

The following commands passed on native Apple Silicon macOS with Zig 0.16.0 and the macOS 15 deployment target.

- `zig test src/tui/review_body.zig`. All 27 tests passed.
- `zig test --dep bbr -Mroot=src/tui/code_highlighting.zig -Mbbr=src/root.zig --test-filter 'M23 highlighting'`.
- `zig build test-code-highlighting --summary all`. All 22 tests passed.
- `zig build test-code-highlighting test-search-kernel test-inline-markdown test-yank --summary all`. All 184 tests passed.
- `zig build`.
- `zig fmt --check build.zig src tests`.
- `git diff --check`.
- `zig build test --summary all`. All 1,071 tests passed.

The first full-suite attempt exceeded the tool's 120-second limit.
The longer run found an omitted command case in the scripted test executor.
The executor now returns a correlated launch failure for the new command.
The final full-suite run passed with a 600-second limit.

## Review

The Standards and Spec reviews used starting commit `9980b3c`.
The Standards fixes share source-to-cell mapping and visible-card lookup, and move block eligibility into the code-block module.
The Spec fixes count Frame annotation capacity and add complete rendering, offscreen eviction, and mouse-completion checks.
Both follow-up reviews found no remaining findings.
