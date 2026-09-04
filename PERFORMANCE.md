# Performance plan

This document merges three independent performance analyses of bbr into one plan:

- `PERFORMANCE_fab.md` — action table with Ghostty pattern sources.
- `PERFORMANCE_sol.md` — static analysis with ranked bottleneck hypotheses and required proof per action.
- `PERFORMANCE_grk.md` — priority-banded action list with SIMD applicability notes.

All three analyses compare bbr with Ghostty (`/Volumes/Work/Github/ghostty`) and review the Tree-sitter integration against the vendored `v0.26.9` API and editor practice (Neovim, Helix, Zed).

The shared direction is data-oriented design: contiguous cache-friendly layouts, struct-of-arrays for scanned data, indexes instead of rescans, no allocation on hot paths, and SIMD only for measured simple scans.

This is a static analysis. No bbr benchmark exists today, and first-party `src/` has no `@Vector` or `std.simd` use. Every ranking below is a bottleneck hypothesis until the benchmark harness confirms it. Action 0 is the prerequisite for everything else.

All line numbers were rechecked against bbr `09ffc95` (the current branch base) on 2026-09-03.

## Hot paths

| Tier | Trigger | Work today |
|---|---|---|
| Per event | Every keypress and mouse motion | `dispatch` → `drainPresentationCommands` → `ensureFocusedEnrichment` → full draw → `vx.render` (src/tui/app.zig:150-237) |
| Per rebuild | Fold toggle, layout change, draft save, file focus | Full `Buffer` + `VisualRow` + file-tree rebuild into `ArenaRing(2)` (src/tui/presentation.zig:1669-1724) |
| Per Session | PR load, file enrichment | Diff parse, blob fetch, tree-sitter highlight on workers |

What bbr already does right (keep, do not touch):

- Zero-copy diff: `Line.text`, paths, and hunk headers borrow RawDiff bytes (src/diff/model.zig).
- `ArenaRing(2)` for buffers and a retained-capacity frame arena (src/tui/arena_ring.zig).
- Off-thread file enrichment with bounded two-request Session acquisition (src/tui/session.zig:102-213).
- Draw limited to visible rows; libvaxis diffs cells internally.

## Action table

Priority bands: P0 = do first, P1 = after P0 is measured, P2 = only with profile evidence. Impact names the hot path that the action improves.

### P0 — measurement and allocation bugs

| # | Action | Location | Hot path | Notes and required proof |
|---|---|---|---|---|
| 0 | Build a benchmark harness (`zig build bench`). ReleaseFast headless benchmarks with stage timers. One file per benchmark, deterministic synthetic fixtures, generation outside timing. Record median, p95, allocation count, peak bytes, retained bytes, and output checksums. Compare medians with hyperfine, one binary per branch. | new `src/benchmark/` | prerequisite | Pattern: Ghostty `src/benchmark/` + `src/synthetic/`, methodology in its `AGENTS.md`. |
| 1 | Fix side-by-side matching. Replace `page_allocator` in the matching DP with a bounded scratch workspace (not the Buffer arena directly, because per-pair frees would retain every temporary allocation). Bound the work by replacement-block area and per-line token product. Fall back to index pairing or whole-line emphasis over the limit. | src/tui/buffer.zig:695-789 (`page_allocator` at 706), src/diff/intraline.zig:157-174 | rebuild | Each removed×added pair does 3+ mmap-backed allocations today. Work grows as `O(R * A * T_old * T_new)`. Benchmark 10x10, 100x100, 500x500 replacement blocks. Assert exact reconstruction and stable pairing below the limit. |
| 2 | Cap the intraline LCS. Bound the token count per line. Use `u32` table cells instead of `usize`. | src/diff/intraline.zig:66-83, src/tui/buffer.zig:1042-1071 | rebuild | Two 2,000-token lines allocate a 32 MB table per pair today. Fixture: a minified `.js`/`.json` line pair. |
| 3 | Compile each tree-sitter query once per Grammar and cache it as one immutable runtime package: highlight query, any locals query, validated predicate tables, RE2 objects, and capture names. Grammars with a locals query repeat the query, predicate, and cursor setup today, and `#match?` predicates rebuild RE2 objects. Keep parsers and query cursors call-local (one `TSParser` + one `TSQueryCursor` per enrichment worker; never share across threads). | src/highlight/tree_sitter_highlighter.zig:100-133, src/highlight/query_predicates.zig:53-71, 139-189 | file focus | `ts_query_new` plus predicate validation and RE2 compiles run on every highlight call today. Query compilation costs tens of ms to seconds per language (Neovim regression, tree-sitter PR #1578). Prerequisite: freeze or synchronize lazy UserGrammar loading (`Registry.grammar` mutates `installation.loaded` without synchronization, src/highlight/user_grammar.zig:242-280). Delete a cached query before its UserGrammar dynamic library closes. |
| 4 | Intern capture names as `u16` query capture ids. Stop `allocator.dupe` per span (30k+ tiny allocations per large file). Resolve capture → theme color through an id → color table at build time, not up to 14 string compares per run per frame in `captureColor`. | src/highlight/tree_sitter_highlighter.zig:184, src/tui/theme.zig:178-192 | file focus + per frame | Pattern: Helix/Neovim capture ids are query-local integers. |
| 5 | Replace the per-byte label + priority planes with a precedence-preserving interval merge `{start, end, id}` over sorted captures, then split on `\n` with `indexOfScalarPos` (SIMD in std). | src/highlight/tree_sitter_highlighter.zig:135-197 | file focus | Two `u32` arrays sized `content.len` = 8 scratch bytes per source byte today; the default 2 MiB limit permits 16 MiB for these arrays per side. High risk: differential-test every Grammar against the current implementation (nested, overlapping, predicate-heavy, invalid, minified input; compare every output Span byte for byte). |
| 6 | Kill the per-event `fileIndexForRow` linear scan. Store a `file_index: u32` per row (or file header ranges) at build time, and delete the duplicate function. Note: cursor/scroll events already skip `prepareBuffer` (`scrollPane` at src/tui/presentation.zig:4292 does not rebuild); the remaining per-event cost is this scan plus the full paint. | src/tui/presentation.zig:6714-6752, callers at 1709, 1734, 5393, 5591, 5990, 6458 (plus `activeFile` at 4183, 4272); src/tui/app.zig:172-175, 194, duplicate fn at 1161-1170 | per event | The scan runs 3-4 times per keypress over a ~100-byte-per-element AoS array. Benchmark cursor movement near the end of a 50,000-row Buffer. Run navigation and mouse hit-test tests. |
| 7 | Monotonic span cursor (or binary search) in `lineSpans`. The cursor is local to the call and restarts at span index 0 per line: `O(L * S)` per rebuild. | src/tui/buffer.zig:842-860 | rebuild | Benchmark a 5,000-line file with sparse and dense Spans in Unified and SideBySide layouts. |
| 8 | Index comment anchors by `(path, line)` in a hash map once per Buffer transaction. Use a set/hash for expanded disclosures instead of the linear `disclosureExpanded` scan. | src/tui/buffer.zig:303-365, 598-604, 794-811, 223-226 | rebuild | Weaving is O(lines × (threads + drafts)) with a path `mem.eql` per check; `emitRepliesTo` is O(drafts²). Benchmark 300 files with 0, 100, 2,000 threads/drafts; differential-test every emitted row and tally. |
| 9 | ASCII fast path for width measurement. Scan each row with `@Vector` compare (`byte >= 0x80`) + `@reduce(.Or)`. A pure-ASCII run has `width == len` and needs zero grapheme work. Batch the vtable call per run, not per grapheme. | src/tui/cell_metrics.zig:8-36, src/tui/frame.zig:192-243, src/tui/app.zig:284-288 | rebuild + resize | Diff content is overwhelmingly ASCII. Pattern: Ghostty `@Vector` early-exit scan (src/terminal/stream.zig:750-771). Keep a scalar reference and differential-test all lengths, alignments, controls, UTF-8. |
| 10 | Paint gutters from a stack `[N]u8` buffer, not `allocPrint` per column (`numCol` prints twice per visible line). Apply cursor-row style while drawing; never `readCell`+`writeCell` the whole row (`highlightCursorRow`). Prefer one `printSegment` of spaces over per-column `fillRow`. | src/tui/render.zig:1070-1072 (callers 291-293, 346-348), 315-323, 1075-1079 | per frame | Thousands of small `allocPrint` calls per frame for a fixed 4-char field. |

### P1 — repeated work and memory retention

| # | Action | Location | Hot path | Notes and required proof |
|---|---|---|---|---|
| 11 | Split the Highlighter's scratch allocator from its result allocator. Release scratch after each side; retain only the blob and final Spans. Add a retained-capacity limit for Buffer and frame arenas after unusually large reviews. | src/tui/file_enrichment.zig:130-194 | memory | Scratch capacity is retained with the File Enrichment result today. Measure peak and retained bytes at 4 KiB, 100 KiB, 1 MiB, and 2 MiB per BuiltInGrammar. |
| 12 | Cache `ReviewBody.parse` per comment per Session. Split the whole-file blob into a line-start index `[]u32` once at enrichment admit (`spliceOldSide`/`splitBlobLines` walk `\n` per rebuild today, and the Highlighter walks it again). Reproject only width-dependent rows. | src/tui/buffer.zig:508-574, 877-986 | rebuild | Markdown re-parses and the immutable blob re-splits on every rebuild today. The ReviewBody CONTEXT.md already promises this cache. Session and Draft mutation must invalidate the right data. |
| 13 | Split and shrink `VisualRow`. Stop embedding the ~112-byte `Row` union; keep `buffer_index` and hot navigation fields, read the cold `Row` through the Buffer. Add a parallel `[]RowKind` byte array (SoA) next to `buffer.rows` so tag scans touch 1 byte per row and become `@Vector`-scannable. | src/tui/frame.zig:84-94, 412-480; src/tui/buffer.zig:146-157 | rebuild + per event | A 50k-row PR reallocates ~16 MB per rebuild today; `restoreNavigation`/`findVisualRow`/`findOwner` scan linearly. Pattern: Ghostty hot data dense, cold data out-of-band. Split fields only after a profile shows a hot loop reads a small stable subset. |
| 14 | Shrink `diff.Line` and `Span`. `?u32` costs 8 bytes; line numbers are 1-based, so 0 works as the null sentinel. `Span` with `u32` offsets + `u16` capture id drops from 40+ bytes to ~14. | src/diff/model.zig:18-31, span type in src/highlight/ | rebuild | 3× cache density for the span scans in action 7. Record `@sizeOf`, bytes per projected line, and scan time before and after. |
| 15 | Deduplicate projection work. Reuse one file tally array in Buffer and File Tree (or delete the unused `file_tallies`). Stop `measured_cells` width measurement for unwrapped rows if no consumer reads it. | src/tui/buffer.zig:424-435, 1179-1200, src/tui/file_tree.zig:123-158, src/tui/frame.zig:335-350 | rebuild | Definite duplicate work; total cost needs measurement. |
| 16 | Wrap the viewport (plus small overscan) or cache wrap results until width, wrap mode, or buffer generation changes. | src/tui/frame.zig:192 (`buildVisualRowsWithOptions`) | rebuild | The entire buffer wraps on every `prepareBuffer` today. |
| 17 | Cache highlight results by `(grammar, blob identity)` on the Session. Reuse when the old and new side share the same blob. | src/tui/file_enrichment.zig | file focus | Content-addressed cache; both sides can re-parse the same bytes today. |
| 18 | Pre-size diff parser lists from hunk header counts (`old_count + new_count`). | src/diff/parser.zig:30-241 | Session load | Tiny effort, low impact. |

### P2 — only with profile evidence

| # | Action | Notes |
|---|---|---|
| 19 | Parser and cursor pools; measured parser deadlines (progress callback, ~3 ms yield); query match limit (Helix uses 256) as a tail guard. Reject the complete highlight result when `did_exceed_match_limit` is true. Call `ts_parser_reset` before reusing a cancelled parser. | Only if setup exceeds a material share of warm highlight time after action 3. The plumbing exists (`match_limit` param at tree_sitter_highlighter.zig:100, set at 132) but the production path passes null, which sets `maxInt(u32)`. Note: `ts_parser_set_timeout_micros` is deprecated since tree-sitter 0.25. |
| 20 | Range-limited query (`ts_query_cursor_set_byte_range`) around visible hunks with a margin. | Only if highlight still stalls after actions 3-5. Range-limited queries cut worst-case times roughly in half (tree-sitter discussion #1976), but the current Highlighter contract, WholeFile display, and Review Search need complete file Spans. |
| 21 | Split Buffer, visual-row, and File Tree invalidation; dirty regions for sidebar vs diff vs overlay; `frame_revision` as a skip-draw signal (revisions exist, but every event still paints). | High risk: partial invalidation can publish inconsistent navigation data. Only if stage timers show repeated unrelated work. |
| 22 | Own a SoA cell row (`gcluster, width, fg, bg`) and blit to vaxis once; skip `win.clear()` (src/tui/render.zig:71, 88, 1055) when every cell is written. Then vectorized row fill, style splat, and row equality. | This is the primary SIMD surface, and it only exists after action 13. |
| 23 | Shared HTTP connection reuse and concurrent old/new side fetches. | Separate experiment tier. Each remote worker creates and destroys an HTTP client today (src/tui/app.zig:771-813, `StdHttpClient.init` at 785). Keep request bounds and Bitbucket rate-limit behavior visible. Record 429 responses. Do not mix with CPU benchmarks. |
| 24 | Inspect `memset` disassembly in the ReleaseFast profile. Zig 0.16 generated a scalar `memset` that made one Ghostty benchmark 2.8× slower. | First remove large fills (action 5 removes the biggest). Do not add a global override without bbr's own evidence. |

## Suggested order

1. Action 0 (harness) — nothing is measured today.
2. Actions 1, 2 (allocation bugs) — pathological inputs can hang the rebuild.
3. Actions 3, 4, 5 (tree-sitter setup, interning, interval merge) — the cheapest large-file win.
4. Actions 6-9 (per-event and per-rebuild scans) — the felt latency. Cursor/scroll already skip the rebuild; the win is the scans and the paint.
5. Action 10 (draw allocations).
6. Actions 11-18 — measure after the above; some may stop mattering.
7. P2 actions — only with profile evidence.

Measure after each band with a large PR (multi-MB diff, dense comments, wrap on) before starting SIMD work.

## Actions to not take

| Non-action | Reason |
|---|---|
| Incremental tree-sitter parsing (`ts_tree_edit`) | bbr content is immutable per Session and parses once per side. bbr does not own the exact `TSInputEdit` sequence the API requires. Full `parse_string` on a contiguous buffer is the documented right call. |
| Tree-sitter injections | Injections dominate cost in large files and are a correctness nicety. Skip for a one-shot viewer. |
| Chunked `TSInput` read callback | bbr holds blobs as contiguous slices. `parse_string` is simpler and has no per-chunk overhead. |
| Included parser ranges for diff hunks | A Grammar can need syntax outside a hunk to classify a capture correctly. Included ranges fit embedded languages, not partial coloring. |
| One global tree-sitter parser or query cursor | Both carry mutable execution state; active workers need exclusive ownership. |
| Tree-sitter allocation override per worker | The allocator hook is process-global and the default aborts on failure. |
| bbr-side terminal dirty tracking | vaxis diffs cells internally, so terminal I/O is already bounded. The waste is in projection work upstream, which the P0/P1 actions address. |
| SIMD in the diff parser | `splitScalar`/`startsWith` already use std's vectorized `indexOfScalar`. |
| SIMD in the LCS or tree-sitter traversal | LCS cells depend on neighbors; tree-sitter owns its lexer. Bound or replace the algorithm instead. |
| Pack every Diff and Buffer struct | Ghostty packs fixed terminal cells. bbr's rows carry varied semantic data. Compact a hot field subset only after a profile identifies it. |
| Porting Ghostty's GPU glyph atlas / Metal path | Not applicable to a TUI. |
| A global `memset` override | Ghostty added one for a measured regression. bbr needs its own profile and disassembly evidence (P2 action 24). |
| Copying Ghostty's 4-buffer PTY pipeline | bbr has request-level I/O, not a saturated byte stream. |

## Benchmark corpus

Deterministic generated fixtures; keep generation outside the timed process. Run CPU benchmarks without network access. Run acquisition and transport checks as a separate tier.

| Fixture | Exercises |
|---|---|
| RawDiff with 300 files and 50,000 hunk lines, cursor at the bottom | Diff parse, Buffer, visual rows, File Tree, navigation (actions 0, 6, 13), retained arenas |
| The same diff with 0, 100, and 2,000 threads and drafts | Placement indexes, tallies, ReviewCard costs (action 8) |
| Replacement blocks from 10x10 through 500x500 | Side-by-side matching and fallback limits (action 1) |
| Minified line pairs, 10 through 4,000 lexical parts per line | Intraline LCS time, workspace size, fallback limits (action 2) |
| BuiltInGrammar files at 4 KiB, 100 KiB, 1 MiB, 2 MiB (incl. a 5k-line TSX file) | Tree-sitter cold and warm phases, peak and retained memory (actions 3-5, 11) |
| Valid, invalid, minified, predicate-heavy source | Tree-sitter tail behavior and interval-merge equivalence (action 5) |
| Buffers with ASCII, tabs, controls, combining marks, wide glyphs, invalid UTF-8 boundaries | Cell width and SIMD differential tests (action 9) |
| Large-review then small-review sequence | Retained arena capacity and release policy (action 11) |

## Ghostty patterns worth adopting long-term

These shape future code rather than fix current code. Ghostty's workload differs (continuous high-rate stream, fixed cell grid, GPU renderer); adopt the rules, not the layouts.

- Packed hot structs: Ghostty's terminal cell is one `packed struct(u64)`; compare, copy, and reset are single register ops. Cold data lives in side tables. Apply the split when reworking `Row`/`VisualRow` (actions 13-14).
- `@Vector` early-exit scan idiom: vector compare + `@reduce(.Or)` + `@ctz` on the bitcast bool vector, then a scalar tail. LLVM does not auto-vectorize early-exit loops. (Actions 9, 13.)
- Never-false-negative flag bits: cheap boolean gates that can be stale-true but never stale-false let hot loops skip work without exact bookkeeping. Ghostty reports ~4× on row erase.
- Offset-based indices over pointers: 32-bit indices into contiguous arrays halve reference size and survive reallocation. (Actions 6, 7, 13.)
- `std.MultiArrayList` when callers read a subset of fields — but only after a profile shows the hot loop reads a small stable subset.
- Comptime lookup tables instead of branch chains.
- Benchmark discipline: fixed synthetic corpora, ReleaseFast, warmups, hyperfine medians, one binary per branch, plus differential tests (optimized vs scalar reference) for every hand-vectorized path. Reported Ghostty speedups belong to Ghostty's workloads; they are not forecasts for bbr.

## Source notes

- bbr at `09ffc95fa09781cb926e261b07775a3f95632a2a`; Ghostty at `09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8`; tree-sitter `v0.26.9` (vendored snapshot).
- Tree-sitter recommendations use the vendored API headers and the official basic-parsing, advanced-parsing, and query API guides (checked 2026-09-03).
- RE2 objects are thread-safe to share once built (vendors/re2/re2/re2.h:292-304), which enables the per-Grammar query package in action 3.
