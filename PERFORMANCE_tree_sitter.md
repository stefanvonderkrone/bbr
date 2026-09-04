# High-performance Tree-sitter for editors and for bbr

Research date: 2026-09-03.

Primary sources: vendored `tree_sitter/api.h` (ABI 15), Tree-sitter docs (basic parsing, advanced parsing, pattern matching), Rust `tree_sitter::Parser` / `Query`, first-party `tree-sitter-highlight` 0.27.

bbr today (`src/highlight/tree_sitter_highlighter.zig`, `query_predicates.zig`): `ts_parser_new` per highlight, `ts_parser_parse_string(..., null, ...)`, `ts_query_new` for highlights and locals every call, `Set.validate` + RE2 compile every call, two `u32` planes of `content.len`, `allocator.dupe` of each capture name, worker-thread highlight of immutable git blobs.

## Facts from the library (not folklore)

| Object | Lifetime / sharing | Source |
| --- | --- | --- |
| `TSParser` | Stateful. Create once, `ts_parser_set_language` when the language changes, `ts_parser_reset` when aborting a cancelled parse and starting a different document. | `api.h` Parser section; `ts_parser_reset` comment |
| `TSQuery` | Built from S-expressions + language. Immutable after create. Safe to share across threads. Compilation is the expensive step. | pattern-matching docs; `Query` rustdoc: “References to Queries can be shared between multiple threads” |
| `TSQueryCursor` | Holds execution state. Do not share across threads. Reuse via `ts_query_cursor_exec` on the same cursor. | pattern-matching docs; `api.h` `ts_query_cursor_new` |
| `TSTree` | Not thread-safe. `ts_tree_copy` is an atomic refcount bump for another thread. | `api.h` `ts_tree_copy`; advanced-parsing concurrency |
| `old_tree` | Only for a later version of the *same* document after `ts_tree_edit`. First parse and unrelated documents pass `NULL`. | `api.h` `ts_parser_parse`; advanced-parsing |
| Contiguous buffer | `ts_parser_parse_string` is the right API when the text is one slice. `TSInput` is for ropes/piece tables. | basic-parsing docs |
| Capture ids | `TSQueryCapture.index` is the query-local integer; `ts_query_capture_name_for_id` maps it to a string. | `api.h` Query section |
| Match limit | Caps in-progress matches, not total captures. `ts_query_cursor_did_exceed_match_limit` is the overflow signal. | `api.h`; pattern-matching |
| Range-limited query | `ts_query_cursor_set_byte_range` returns matches that *intersect* the range. | `api.h` |
| Injections | `ts_parser_set_included_ranges` + a second parse. First-party highlighter takes an injection callback. Cost is extra parses and queries. | advanced-parsing multi-language; `tree-sitter-highlight` usage |

`tree-sitter-highlight` encodes the intended host shape:

- `HighlightConfiguration::new(language, highlights, injections, locals)` once per language.
- `configure(&highlight_names)` maps capture name strings to small integer `Highlight` ids.
- `Highlighter::new()` **once per thread** (owns the parser and query cursor).
- Output is a stream of `HighlightEvent::{Source, HighlightStart, HighlightEnd}`, not a per-byte map.

## Prioritized practices mapped to bbr

Priority: P0 = do first (large win, matches current anti-patterns). P1 = next. P2 = only if still hot. Skip = do not do for this product.

| Pri | Practice | Rationale | Likely bbr change | Current bbr |
| --- | --- | --- | --- | --- |
| P0 | **Compile each query once per grammar.** Cache `TSQuery` + predicate/`#match?` regex set. Compile locals query once too. | `ts_query_new` walks patterns, checks node types, builds an NFA. Host-side `Set.validate` compiles RE2. Editors treat this as load-time. Neovim has shipped regressions from *not* caching. | Long-lived `CompiledGrammar { language, highlights: *TSQuery, locals: *TSQuery, predicates }` keyed by built-in name or user-grammar identity. Init at process start / registry load. `highlightWithQuery` takes compiled objects, not source strings. Same for `Locals.collect`. | `ts_query_new` + `Set.validate` + `Locals.collect` → another `ts_query_new` on every highlight (`tree_sitter_highlighter.zig:111–128`, `query_predicates.zig:53–62`) |
| P0 | **One `TSParser` per highlighting thread.** `set_language` when the grammar changes; `reset` only after a cancelled parse. | Parser holds lexer/stack arenas. Allocating one per file pays setup on the hot path. First-party docs: one `Highlighter` per thread. | Thread-local or worker-owned parser. Enrichment worker already exists; park the parser on that worker. Do not share one parser across concurrent `std.Io.concurrent` tasks. | `ts_parser_new` / `ts_parser_delete` around every parse (`tree_sitter_highlighter.zig:103–105`) |
| P0 | **Reuse one `TSQueryCursor` per thread.** `exec` again; do not `new`/`delete` per file. | Cursor is scratch for in-progress matches. Docs: reuse for many executions; not thread-safe. | Same owner as the parser. Two cursors if highlights and locals run nested (or run them sequentially on one cursor). | `ts_query_cursor_new` twice per file (highlight + locals) |
| P0 | **Intern captures as query-local ids; never `dupe` the name per span.** Resolve id → theme color once. | Capture names are interned inside `TSQuery`. Duplicating them per span is tens of thousands of tiny allocs. Theme `captureColor` then re-compares strings. `HighlightConfiguration.configure` is the model. | `Span.capture: u16` (or interned id into a process-wide name table). Map id → color at compile/configure. Shrink `Span` (pairs with layout work). | `ts_query_capture_name_for_id` + `allocator.dupe` per run (`tree_sitter_highlighter.zig:182–189`). `Capture.name: []const u8` in `highlighter.zig` |
| P1 | **Do not keep a per-byte `u32` label/priority plane.** Merge overlapping captures into intervals, then split on newlines. | Two `u32` arrays = 8 bytes per source byte plus O(bytes × overlapping captures) stores. Capture count is O(tokens), not O(bytes). First-party output is an event/interval stream. | Collect `{start,end,capture_id,pattern_index}` from matches; sort; sweep-line merge with last-pattern-wins (today: later `pattern_index` wins). Split intervals on `\n` with `indexOfScalarPos`. Optional: `ts_query_cursor_next_capture` if ordered captures fit the precedence rule — **verify** against current “later pattern overwrites” tests before switching. | `labels` + `priorities` of `content.len`, inner byte loop (`tree_sitter_highlighter.zig:137–160`) |
| P1 | **Parse from scratch with `old_tree = NULL` for git blobs.** Do not implement `ts_tree_edit`. | Incremental parse is for *edited* buffers. Official contract: first parse and unrelated documents pass `NULL`. Blobs are immutable for a Session. Incremental needs matching byte+point edits; a wrong edit is silent corruption. Keeping trees costs memory with no reuse if content never changes. | Keep `parse_string(parser, null, blob.ptr, len)`. Delete the tree when spans are built. Do not cache `TSTree` unless a later feature mutates the buffer. | Already `null` old tree. This is **correct** for bbr, not an anti-pattern here |
| P1 | **One highlighter context per worker; share compiled queries.** | `TSParser` / `TSQueryCursor` / in-flight `TSTree` are not thread-safe. `TSQuery` is. `TSLanguage` is. Copy a tree (`ts_tree_copy`) only if two threads walk the same tree at once — bbr does not. | Keep highlight off the UI thread (already). Give each worker its own parser+cursor. Share the compiled-query table (immutable). | Worker is right; per-call parser/query construction is the bug, not the thread |
| P2 | **Cache highlight *results* by (grammar, content identity).** | Same blob can appear as old and new, or be re-enriched. Git already names content. Parse+query still dwarf a hash lookup. | Key: built-in or user grammar id + blob sha (or pointer equality of interned blob). Store `HighlightResult`. Invalidate on Session end. Skip if profiling shows highlight is already one-shot per side. | No result cache |
| P2 | **Line index on the blob at admit, not inside the highlighter.** | Highlighter only needs newlines to emit line-relative spans. A Session-scoped line offset table also serves the buffer. | Build `[]u32` start offsets once per side when enrichment admits the blob. Highlighter can take that index or remain a single `\n` scan after interval merge. | Highlighter walks bytes looking for `\n` (`tree_sitter_highlighter.zig:165–197`) |
| P2 | **Match limit as a safety valve, not Helix’s 256 as a quality default.** | Limit is *in-progress* matches. Too low drops real highlights (`QueryMatchLimitExceeded` test uses 0). Helix’s small cap is for interactive editors. | Keep a high cap (or language-specific). Surface exceed as skip/fail, already done. | `maxInt(u32)` unless tests pass 0 |
| P2 | **Range-limited queries around visible hunks.** | `set_byte_range` can cut work on huge files. Matches that intersect the range still return. Easy to miss highlights on nodes that start outside the window. | Only after P0 if huge files still stall. Pad hunk byte ranges. Keep full-file parse (parse is not range-limited the same way unless `included_ranges`). | Full-file query |
| Skip | Incremental `ts_tree_edit` | No in-session mutation of blobs. | None | — |
| Skip | Injections (`included_ranges` + nested highlight) | Extra parses. Correctness nicety for a one-shot diff viewer (markdown fences, HTML `<script>`). Revisit if a grammar’s highlights are wrong without them. | None for now | No injections |
| Skip | Chunked `TSInput` | Blobs are contiguous slices. Callback overhead with no packing win. | Keep `parse_string` | Already correct |
| Skip | SIMD inside Tree-sitter | Lexer/parser are table-driven and pointer-chasing. No stable SIMD API. | Do not vectorize parse. | — |
| P2 (host) | **SIMD / `indexOfScalar` only on post-process.** | Newline scan and run-length of interned ids are dense byte/u16 scans; std already vectorizes `indexOfScalarPos`. | After interval merge, find `\n` with `indexOfScalarPos`. If a dense id plane remains, scan runs with SIMD. | Scalar byte loop |

## Anti-patterns (bbr hits the first four)

1. **`ts_query_new` on every highlight** — compile cost on the file-focus path. Worst offender with `#match?` regexes.
2. **`ts_parser_new` per highlight** — avoidable allocator/setup traffic.
3. **`parse_string` with `NULL` old tree on an *edited* buffer** — editor bug. **Not** a bbr bug: blobs are new documents.
4. **String-copy capture names** — `dupe` + later string compares instead of `capture.index`.
5. **O(file) u32 planes** — memory and write amplification vs interval lists.
6. **Sharing one `TSParser` or `TSQueryCursor` across threads** — data race. One per thread.
7. **Sharing one `TSTree` across threads without `ts_tree_copy`** — documented undefined.
8. **Leaving a cancelled parser without `ts_parser_reset`** — next parse resumes the old document (`api.h` `ts_parser_reset`).
9. **Recompiling `#match?` regexes per file** — belongs next to the cached `TSQuery`.
10. **Treating match limit as “max highlights”** — it is in-progress match state.

## SIMD, restated

Tree-sitter will not be the SIMD win. After P0, remaining host work is: sort/sweep a few thousand intervals, split on newlines, intern ids. Use std’s vectorized scalar search there. Do not add `@Vector` into the C parser.

## Suggested implementation order (bbr)

1. Compiled grammar cache (`TSQuery` + predicates + locals query) — P0.
2. Thread-owned parser + query cursor — P0.
3. Capture id intern and `Span` without owned strings — P0 (API change on `highlighter.zig`).
4. Interval merge instead of per-byte planes — P1.
5. Measure. Only then result cache, line index sharing, range-limited queries.

Keep: worker-thread highlight, `parse_string` + `NULL` old tree, no injections, no chunked `TSInput`.

## Sources

- Vendored API: `vendors/tree-sitter/runtime/include/tree_sitter/api.h` (parser, tree copy, query, query cursor, parse_string, reset).
- [Basic parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html) — `parse_string` vs `TSInput`.
- [Advanced parsing](https://tree-sitter-tree-sitter.mintlify.app/using-parsers/advanced-parsing) — incremental edit, included ranges, tree copy / not thread-safe.
- [Pattern matching](https://tree-sitter-tree-sitter.mintlify.app/using-parsers/pattern-matching) — query immutability, cursor reuse, capture iteration, byte range, match limit.
- [tree-sitter Parser](https://docs.rs/tree-sitter/latest/tree_sitter/struct.Parser.html) — `old_tree` / `reset`.
- [tree-sitter Query](https://docs.rs/tree-sitter/latest/tree_sitter/struct.Query.html) — shared references across threads.
- [tree-sitter-highlight 0.27](https://docs.rs/tree-sitter-highlight/latest/tree_sitter_highlight/) — `Highlighter` per thread, `HighlightConfiguration`, `HighlightEvent`.
- bbr: `src/highlight/tree_sitter_highlighter.zig`, `src/highlight/query_predicates.zig`, `src/highlight/highlighter.zig`.
