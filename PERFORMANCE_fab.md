# Performance plan

This document distills three analyses into one action table for bbr:

1. A performance analysis of the bbr codebase.
2. A pattern survey of Ghostty (`/Volumes/Work/Github/ghostty`), a high-performance terminal emulator in Zig.
3. Research on high-performance tree-sitter integration (tree-sitter docs, Neovim, Helix, Zed).

The direction is data-oriented design: contiguous cache-friendly memory layouts, struct-of-arrays for scanned data, batch processing with `@Vector`, and no allocation on hot paths.

## Hot paths in bbr

| Tier | Trigger | Work today |
|---|---|---|
| Per event | Every keypress and mouse motion | `dispatch` → `drainPresentationCommands` → `ensureFocusedEnrichment` → full draw → `vx.render` (src/tui/app.zig:150-237) |
| Per rebuild | Fold toggle, layout change, draft save, file focus | Full `Buffer` + `VisualRow` + file-tree rebuild into `ArenaRing(2)` (src/tui/presentation.zig:1669-1724) |
| Per Session | PR load, file enrichment | Diff parse, blob fetch, tree-sitter highlight on workers |

No bbr benchmarks exist today. Action 0 is the prerequisite for everything else.

## Action table

Impact: effect on user-visible latency on the listed hot path. Effort: tiny < small < medium.

| # | Action | Location | Hot path | Impact | Effort | Pattern source |
|---|---|---|---|---|---|---|
| 0 | Build a benchmark harness before any optimization. One file per benchmark, deterministic synthetic fixtures (large diff, minified-line pair, 5k-line TSX file, 300-file PR), compare medians with hyperfine. | new `src/benchmark/` | — | prerequisite | small | Ghostty `src/benchmark/` + `src/synthetic/`, methodology in its `AGENTS.md` |
| 1 | Replace `page_allocator` with the build arena in the side-by-side matching DP. Each removed×added pair currently does 3+ mmap-backed allocations. | src/tui/buffer.zig:706 | rebuild | high | tiny | bbr analysis, worst allocation bug found |
| 2 | Cap the intraline LCS. Bound token count per line, use `u32` table cells instead of `usize`. Two 2,000-token lines allocate a 32 MB table per pair today. | src/diff/intraline.zig:66-83, src/tui/buffer.zig:1042-1071 | rebuild | high | small | bbr analysis |
| 3 | Kill the per-event `fileIndexForRow` linear scan. Store a `file_index: u32` per row at build time. The scan runs 3-4 times per keypress over a ~100-byte-per-element AoS array. | src/tui/presentation.zig:6714-6724, callers at 1709, 1734, 5393, 5591, 5990, 6458 (plus activeFile at 4183, 4272); src/tui/app.zig:172-175, 194, duplicate fn at 1161 | per event | high | small | Ghostty: precomputed offsets over pointer walks |
| 4 | ASCII fast path for width measurement. Scan each row with `@Vector` compare (`byte >= 0x80`) + `@reduce(.Or)`. A pure-ASCII run has `width == len` and needs zero grapheme work. Batch the vtable call per run, not per grapheme. Diff content is overwhelmingly ASCII. | src/tui/cell_metrics.zig:27-36, src/tui/frame.zig:192-243, src/tui/app.zig:288-295 | rebuild + resize | high | small | Ghostty `@Vector` early-exit scan idiom (src/terminal/stream.zig:750-771) |
| 5 | Binary search or a per-file `line → span range` offset table in `lineSpans`. The current scan restarts at span index 0 per line: O(lines × spans) per rebuild. | src/tui/buffer.zig:842-861 | rebuild | high | small | data-oriented index tables |
| 6 | Compile each tree-sitter query once per Grammar and cache it. `ts_query_new` plus predicate validation and RE2 compiles run on every highlight call today. Query compilation costs tens of ms to seconds per language. Reuse one `TSQueryCursor`. | src/highlight/tree_sitter_highlighter.zig:100-133 | file focus | high | medium | tree-sitter research: Neovim regression, tree-sitter PR #1578 |
| 7 | Intern capture names as `u16` ids. Stop `allocator.dupe` per span (30k+ tiny allocations per large file) and stop the up-to-14 string compares per run per frame in `captureColor`. Resolve capture → theme color at build time. | src/highlight/tree_sitter_highlighter.zig:184, src/tui/theme.zig:178-192 | file focus + per frame | high | small | Helix/Neovim: capture ids are query-local integers |
| 8 | Bucket comment anchors by (path, line) in a hash map once per build. Comment weaving is O(lines × (threads + drafts)) with a path `mem.eql` per check, and `emitRepliesTo` is O(drafts²). | src/tui/buffer.zig:794-812, 598-604 | rebuild | medium | small | bbr analysis |
| 9 | Cache `ReviewBody.parse` per comment per Session. Markdown re-parses on every rebuild; only projection depends on terminal width. | src/tui/buffer.zig:517, 557 | rebuild | medium | small | bbr analysis (the ReviewBody CONTEXT.md already promises this) |
| 10 | Split the whole-file blob into a line index once at enrichment admit, not per rebuild. The blob is immutable per Session. | src/tui/buffer.zig:877-986 (`spliceOldSide`/`splitBlobLines`) | rebuild | medium | tiny | bbr analysis |
| 11 | Shrink and split `VisualRow`. Stop embedding the ~112-byte `Row` union; index into buffer rows instead. Move hot fields (owner tag, buffer index, source range) into parallel arrays. A 50k-row PR reallocates ~16 MB per rebuild today, and `restoreNavigation`/`findVisualRow`/`findOwner` scan it linearly. | src/tui/frame.zig:84-108, 412-480 | rebuild + per event | medium | medium | Ghostty: hot data dense, cold data out-of-band (packed Cell + side tables) |
| 12 | Add a parallel `[]RowKind` byte array (SoA) next to `buffer.rows`. Tag scans (`fileIndexForRow`, `nextFileHeaderRow`) then touch 1 byte per row instead of ~100, and become `@Vector`-scannable. | src/tui/buffer.zig:146-157, src/tui/presentation.zig:6726-6753 | per event | medium | small | Ghostty MultiArrayList dirty column (src/terminal/render.zig:462-501) |
| 13 | Shrink `diff.Line` and `Span`. `?u32` costs 8 bytes; line numbers are 1-based so 0 works as the null sentinel. `Span` with `u32` offsets + `u16` capture id drops from 40+ bytes to ~14: 3× cache density for action 5's scans. | src/diff/model.zig:18-31, span type in src/highlight/ | rebuild | medium | medium | Ghostty packed structs: Cell/Row as `packed struct(u64)` |
| 14 | Replace the per-byte label arrays in span extraction with an interval merge over sorted captures. Two `u32` arrays sized `content.len` (8 bytes per source byte) plus O(bytes × overlapping captures) writes today. Use `indexOfScalarPos` (SIMD in std) for the newline scan. | src/highlight/tree_sitter_highlighter.zig:138-197 | file focus | medium | medium | Helix `HighlightEvent` streaming model |
| 15 | Precompute gutter number strings or reuse a fixed buffer. Thousands of small `allocPrint` calls per frame for a fixed 4-char field. | src/tui/render.zig:291-295, 346-350, 203, 209 | per frame | low | tiny | Ghostty: no hot-path allocation |
| 16 | Pre-size diff parser lists from hunk header counts (`old_count + new_count`). | src/diff/parser.zig:30-241 | Session load | low | tiny | bbr analysis |

## Actions to not take

| Non-action | Reason |
|---|---|
| Incremental tree-sitter parsing (`ts_tree_edit`) | bbr content is immutable per Session and parses once per side. Full `parse_string` on a contiguous buffer is the documented right call for read-mostly tools. |
| Tree-sitter injections | Injections dominate cost in large files and are a correctness nicety. Skip for a one-shot viewer. |
| Chunked `TSInput` read callback | bbr holds blobs as contiguous slices. `parse_string` is simpler and has no per-chunk overhead. |
| bbr-side terminal dirty tracking | vaxis diffs cells internally, so terminal I/O is already bounded. The waste is in projection work upstream of vaxis, which actions 1-14 address. |
| SIMD in the diff parser | `splitScalar`/`startsWith` already use std's vectorized `indexOfScalar`. Nothing to gain. |

## Deferred tree-sitter options

Apply only if profiling after action 6 still shows highlight stalls:

- Restrict the query cursor to a byte range (`ts_query_cursor_set_byte_range`) around the visible hunks instead of the whole file, with a small margin. Range-limited queries cut worst-case times roughly in half (tree-sitter discussion #1976).
- Set a match limit on the cursor (Helix uses 256). The plumbing exists (`match_limit` in tree_sitter_highlighter.zig:100,132) but the production path passes null, which sets `maxInt(u32)`.
- Time-slice the parse with `ts_parser_parse_with_options` and a progress callback that yields after ~3 ms, Neovim-style. Note: `ts_parser_set_timeout_micros` is deprecated since tree-sitter 0.25.

## Ghostty patterns worth adopting long-term

These go beyond the action table. They shape future code rather than fix current code.

- **Packed hot structs**: Ghostty's terminal cell is one `packed struct(u64)`. Compare, copy, and reset are single register ops. Cold data (graphemes, hyperlinks) lives in side tables. Apply the same split when reworking `Row`/`VisualRow` (actions 11-13).
- **`@Vector` early-exit scan idiom**: vector compare + `@reduce(.Or)` + `@ctz` on the bitcast bool vector, then a scalar tail. LLVM does not auto-vectorize early-exit loops, so write them by hand (action 4, action 12 scans).
- **Never-false-negative flag bits**: cheap boolean gates that can be stale-true but never stale-false let hot loops skip expensive work without exact bookkeeping. Ghostty reports ~4x on row erase from this.
- **Offset-based indices over pointers**: 32-bit indices into contiguous arrays halve reference size and survive reallocation. Actions 3, 5, 11 all move in this direction.
- **Comptime lookup tables**: generate state and classification tables at comptime with build-time validation, instead of branch chains at runtime.
- **Benchmark discipline**: fixed synthetic corpora, `ReleaseFast`, hyperfine medians, one binary per branch, plus differential tests (optimized vs scalar reference) for every hand-vectorized path.

## Suggested order

1. Action 0 (harness) — nothing is measured today.
2. Actions 1, 2 (allocation bugs) — pathological inputs can hang the rebuild.
3. Actions 3, 4, 5 (per-event and per-rebuild scans) — the felt latency.
4. Actions 6, 7 (tree-sitter caching) — file-focus latency.
5. Actions 8-14 (layout and cache density) — measure after the above, some may stop mattering.

Pathological test inputs: a minified `.js`/`.json` line pair (action 2), a 100+/100+ replaced block (action 1), a 5k-line TSX file (actions 5-7, 14), a 300-file PR with the cursor at the bottom (actions 3, 4, 11).
