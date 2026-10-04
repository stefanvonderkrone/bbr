# 11 — Highlight fenced code with bounded background work

**What to build:** Show plain fenced code immediately, then add available syntax colors without blocking terminal input. Bound retained results and preserve a complete usable Frame after failures or stale work.

**Blocked by:** 06 — Present literal code blocks and Suggestions.

**Status:** ready-for-agent

- [ ] Select a fence Grammar from its first whitespace-separated information token without ASCII case sensitivity. Later tokens affect neither selection nor visible fence labels.
- [ ] Use the approved alias-to-suffix table through normal GrammarMatch and synthetic paths without File acquisition.
- [ ] Valid unlisted identifiers supply their normalized extension. Require an ASCII letter or digit first, then only letters, digits, underscores, plus signs, or hyphens.
- [ ] Reject paths, MIME types, and attribute syntax for Grammar selection. Keep their complete recognized code presentation plain.
- [ ] Preserve normal UserGrammar precedence and shebang fallback. A failed UserGrammar permits one matching BuiltInGrammar attempt before plain fallback.
- [ ] Keep unlabelled fences and ordinary indented code plain without Grammar inference. Add no runtime dependency or shipped Grammar.
- [ ] Publish plain code first. Run complete-block analysis off the terminal input path through typed commands and owned completions.
- [ ] A visible ReviewCard makes all its blocks eligible, including code hidden by body disclosure. Run at most one code-block worker.
- [ ] Choose pending work in displayed card order, then authored block order. Recompute eligibility from the current projection without an unbounded copied-body queue.
- [ ] Skip work that loses eligibility before launch. Let started work finish even after its card leaves the viewport.
- [ ] Apply the existing Highlighting byte limit to each complete block after structural indentation removal. Exactly-at-limit blocks qualify. Zero means unlimited.
- [ ] Oversized blocks retain complete plain content without prefix-only colors. Add no timeout or new setting.
- [ ] Keep a fixed 8 MiB Session budget for successful retained results, measured by allocation capacity.
- [ ] Exclude authored storage, body metadata, and temporary worker scratch storage from that budget. Release worker scratch storage after analysis.
- [ ] Evict least recently used results outside visible presentations first, then other results as needed. A result larger than the budget remains plain without a repeated analysis loop.
- [ ] Permit an evicted successful block to run again after its card leaves and re-enters the viewport. Do not repeat it immediately.
- [ ] Keep bounded failure and size-skip state with body-block identity. Only body or Session replacement permits a fresh attempt.
- [ ] Correlate completions with Session Epoch, typed owner, block, content, and Grammar context. Dispose of accepted or rejected owned completions exactly once.
- [ ] Retain accepted results across wrapping, resize, disclosure, and Theme changes. Theme changes remap Capture roles without new analysis.
- [ ] Admit colors through one complete Presentation Frame. Failure preserves the previous Frame, text, geometry, ownership, cursor, Selection, and occurrence identity.
- [ ] Use existing diagnostics for technical failures without repeated status messages. Plain fallback uses ordinary foreground and the agreed code background.
- [ ] Verify observable scheduling, Grammar fallback, byte boundaries, capacity budget, eviction, retry triggers, stale work, launch failure, and admission rollback.
- [ ] Run `zig build test --summary all`.

## Contract

Use the [approved Highlighting answer](../../m23-comment-thread-markdown-presentation-fixes/issues/05-choose-reviewbody-code-block-highlighting.md#answer), including its exact alias table and acceptance examples.
ADR-0012 governs commands, completions, and publication. The existing Highlighter supplies foreground Spans.
Ticket 12 adds Suggestion context and selected Preview eligibility to this same worker and budget.
