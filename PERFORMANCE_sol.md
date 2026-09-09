# bbr performance analysis

Date: 2026-09-03

This report compares bbr with Ghostty and reviews bbr's Tree-sitter integration. It focuses on data layout, cache locality, bounded work, and SIMD.

The analysis used these revisions:

- [bbr `09ffc95fa09781cb926e261b07775a3f95632a2a`](https://github.com/stefanvonderkrone/bbr/tree/09ffc95fa09781cb926e261b07775a3f95632a2a)
- [Ghostty `09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8`](https://github.com/ghostty-org/ghostty/tree/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8)
- [Tree-sitter `v0.26.9`](https://github.com/tree-sitter/tree-sitter/tree/v0.26.9), which bbr [vendors as a source snapshot](vendors/tree-sitter/README.md#L1-L12)

This is a static analysis. No CPU profile or application benchmark supports a claim that one candidate dominates real PullRequests. The report marks measured Ghostty results as measured. All bbr rankings are bottleneck hypotheses until the proposed benchmarks confirm them.

## Conclusions

1. Add a local CPU and memory benchmark before changing data layouts. bbr has a live acquisition gate, but it has no benchmark for Diff parsing, Buffer construction, Presentation Frame construction, Highlighting, or rendering.
2. Bound SideBySide matching first. Its nested line-pair search calls a token LCS for every removed and added Line pair. The work can grow as `O(R * A * T_old * T_new)`.
3. Fix Highlighting memory next. The current postprocessor allocates two `u32` arrays per source byte. Its arena retains the freed scratch capacity with the File Enrichment result.
4. Reduce repeated work before making structs smaller. Span lookup, Comment and Draft placement, File Tree tallies, and row-to-File lookup all rescan data that can be indexed once.
5. Cache immutable Tree-sitter query state, but keep parsers and query cursors exclusive to one active Highlighting call.
6. Do not start with SIMD. First remove work and improve data access. Add vector code only when a ReleaseFast profile identifies a simple byte or packed-item scan as material.

## Current performance shape

| Stage | Current design | Assessment |
|---|---|---|
| Remote Session acquisition | bbr shares one HTTP client and runs at most two requests at once. Comments wait for PullRequest commit data. | Good bounded concurrency. [Source](src/tui/session.zig#L102-L213) |
| Local Session acquisition | bbr resolves Refs and gets the Diff through sequential GitClient calls. | Process and I/O latency can dominate. Measure before changing it. [Source](src/tui/session.zig#L298-L339) |
| Diff load | `Line.text`, paths, and Hunk headers borrow RawDiff bytes. The parser allocates only backing arrays. | Good zero-copy ownership and contiguous arrays. [Source](src/diff/model.zig#L1-L7) |
| File Enrichment | Each side owns one arena. bbr reads old and new sides in sequence, then runs Highlighting. | Clear ownership, but scratch capacity becomes retained capacity. [Source](src/tui/file_enrichment.zig#L135-L194) |
| Presentation Frame | `prepareBuffer` builds the Buffer, visual rows, and File Tree in one transaction. | Safe atomic publication, but unrelated changes can repeat all three projections. [Source](src/tui/presentation.zig#L1669-L1723) |
| Buffer | One arena owns rows and derived data. `ArenaRing(2)` keeps the prior Buffer valid and retains capacity. | Good steady-state allocation behavior. A large review can leave both arenas large. [Source](src/tui/arena_ring.zig#L1-L61) |
| Draw | bbr draws only visible rows. libvaxis then renders the terminal state. The frame arena retains capacity. | Do not add bbr dirty-row state unless profiles show draw work dominates. [Source](src/tui/render.zig#L244-L264), [event loop](src/tui/app.zig#L182-L236) |

## Ranked bbr bottleneck hypotheses

| Rank | Candidate | Static evidence | Scale or cost |
|---|---|---|---|
| 1 | SideBySide change matching | For every removed-added Line pair, bbr calls `matchingSimilarity`. Each call tokenizes both Lines and builds a full LCS table with `page_allocator`. A second matrix aligns the Line block. [Source](src/tui/buffer.zig#L695-L789), [matching](src/diff/intraline.zig#L157-L174), [LCS](src/diff/intraline.zig#L46-L83) | `R * A` LCS runs. Each LCS uses `O(T_old * T_new)` time and memory. Long minified Lines and large replacement blocks are the worst case. |
| 2 | Highlighting postprocessing | bbr allocates `labels` and `priorities` as `u32[content.len]`. It writes every byte covered by every accepted Capture. [Source](src/highlight/tree_sitter_highlighter.zig#L135-L162) | At least eight scratch bytes per source byte, before the syntax tree, queries, predicates, Locals, and output Spans. The default 2 MiB limit permits 16 MiB for these two arrays per side. [Limit](src/tui/config.zig#L19-L23) |
| 3 | Full reprojection | One `prepareBuffer` call rebuilds the Buffer, visual rows, and File Tree. [Source](src/tui/presentation.zig#L1669-L1723) | Work grows with all projected Lines, ReviewCards, Files, and terminal-width calculations. The trigger frequency needs measurement. |
| 4 | Span lookup | `lineSpans` starts at Span zero for every Line. [Source](src/tui/buffer.zig#L841-L860) | Worst-case `O(L * S)` scans for `L` Lines and `S` Spans on one side. |
| 5 | Comment and Draft placement | Buffer construction scans all Threads and root Drafts at each File and each anchorable Hunk Line. [Source](src/tui/buffer.zig#L303-L365), [inline placement](src/tui/buffer.zig#L791-L811) | Work grows with Lines times Threads and Drafts. Repeated path comparisons add cache misses. |
| 6 | Repeated File lookup | Both Presentation and the event loop scan Buffer rows from the start to map a cursor row to a File. [Source](src/tui/presentation.zig#L6714-L6752), [event loop helper](src/tui/app.zig#L1161-L1170) | A cursor near the end of a large all-Files Buffer makes each lookup linear. |
| 7 | Repeated query setup | Each highlighted side creates a parser, a highlight query, predicate tables, and a query cursor. Grammars with a locals query repeat the query, predicate, and cursor setup. `#match?` predicates also rebuild RE2 objects. [Source](src/highlight/tree_sitter_highlighter.zig#L100-L133), [Locals setup](src/highlight/query_predicates.zig#L50-L71), [predicate setup](src/highlight/query_predicates.zig#L139-L189) | Setup repeats for every highlighted side. Its share of total Highlighting time is not measured. |
| 8 | Duplicate and unused projection work | Buffer computes `file_tallies`, but File Tree scans Threads and Drafts again. Runtime code does not read `file_tallies`. Unwrapped visual rows also compute `measured_cells`, which runtime code does not read. [Buffer tally](src/tui/buffer.zig#L424-L435), [tally calculation](src/tui/buffer.zig#L1179-L1200), [File Tree tally](src/tui/file_tree.zig#L123-L158), [unwrapped rows](src/tui/frame.zig#L335-L350) | Definite work exists. Its total cost can be small unless the review is large. |
| 9 | Width-independent data rebuilt at each projection | Buffer construction parses each Comment and Draft body. WholeFile projection splits the same immutable blob into Lines again. [ReviewBody](src/tui/buffer.zig#L508-L574), [blob split](src/tui/buffer.zig#L875-L986) | Cost grows with repeated rebuilds, ReviewBody size, and WholeFile size. |
| 10 | New transport per remote File Enrichment | Each remote worker creates and destroys an HTTP client. Old and new sides load in sequence. [Source](src/tui/app.zig#L771-L813), [side sequence](src/tui/file_enrichment.zig#L135-L144) | Network latency can dominate File focus. Shared connection and side concurrency need safety and rate-limit tests. |

## Data-oriented design assessment

bbr already has two useful data-oriented choices. The Diff stores borrowed text in contiguous backing arrays. File Enrichment also keeps File-indexed side data, which avoids object graphs and duplicate blob copies.

The next data-oriented changes must target observed access patterns. A broad struct-of-arrays rewrite would add complexity before bbr knows which fields cause cache pressure.

| Access pattern | Current layout | Smallest useful change |
|---|---|---|
| Map a visual row to its File | Scan `Buffer.rows` union tags from row zero. | Store `file_index` on each visual row, or store File header ranges once per Buffer. |
| Get one Line's Spans | Scan an ordered Span slice from index zero. | Use one monotonic cursor per File side during Buffer construction. Compare it with binary search. |
| Place Threads and Drafts | Scan all items for each File and Hunk Line. | Build contiguous indexes keyed by File and line once per Buffer transaction. Store ranges into one ordered item array. |
| Build File Tree tallies | Recount Threads and Drafts after Buffer already computes tallies. | Use one tally array for both projections, or delete the Buffer tally if direct File Tree counts measure faster. |
| Store highlight precedence | Use two dense `u32` arrays indexed by every source byte. | Sweep Capture interval boundaries and emit non-overlapping Spans directly. Preserve pattern precedence exactly. |
| Walk visual rows | Each `VisualRow` copies a full `Row` union and adds navigation data. | If cache profiles point here, retain `buffer_index` and hot navigation fields. Read the cold `Row` through the Buffer. |

Ghostty uses `std.MultiArrayList` when callers read a subset of row fields. The source states that this layout improves cache locality for those reads. [Ghostty source](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/render.zig#L90-L102). bbr must use the same rule, not the same layout: split fields only after a profile shows that a hot loop reads a small stable subset.

## Ghostty findings

Ghostty's performance work is useful because it records measurements beside several changes. Its workload is still different. Ghostty processes a continuous high-rate terminal stream and renders a fixed cell grid. bbr is event-driven and projects irregular Diff and Review data.

| Ghostty design | Evidence | bbr decision |
|---|---|---|
| Use deterministic inputs, ReleaseFast, warmups, repeated serial runs, and medians. Keep generation outside timing. | [Benchmark guidance](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/benchmark/AGENTS.md#L3-L48) | Adopt now for bbr's benchmark harness. |
| Retain render state and update dirty regions instead of cloning the screen. The old clone blocked I/O. | [RenderState](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/render.zig#L25-L71) | Do not copy yet. bbr is event-driven and already limits drawing to visible rows. First measure Buffer and frame stages separately. |
| Copy common raw cells first, then process only cells with managed state. Ghostty reports about 300 percent faster plain-text screen cloning. | [RowBuilder](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/render.zig#L1161-L1212) | Apply the principle to common runs. Build indexes once, then handle exceptional Comments, Drafts, Captures, and Unicode data out of band. |
| Pack row and cell metadata, then scan groups with masks and vectors. | [Mask](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/page.zig#L2357-L2447) | Suitable only for small homogeneous values. bbr's semantic `Row` union is not a terminal Cell. Prefer a compact side index over packing the whole union. |
| Reuse per-row arenas and backing arrays. Ghostty warns that a large frame can retain excess memory. | [Capacity reuse](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/render.zig#L65-L71), [row reuse](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/render.zig#L1146-L1182) | bbr already reuses Buffer and frame arenas. Add retained-capacity metrics and a policy to release unusually large arenas. |
| Split PTY reads and parsing through four fixed 64 KiB buffers. Ghostty measured no gain above four buffers on an M4 Max. | [PTY pipeline](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/termio/Exec.zig#L1268-L1317) | Do not copy. bbr has request-level I/O, not a saturated byte stream. Its existing two-request Session bound follows the same measurement-led approach. |
| Use SIMD for ASCII runs, packed-value masks, and measured memory primitives. | [ASCII vector path](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/simd/vt.zig#L19-L79), [group masks](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/terminal/page.zig#L2357-L2447) | Keep as a later tool for simple scans. Do not vectorize dependent LCS cells or Tree-sitter traversal. |
| Zig 0.16 generated a scalar `memset` that made one Ghostty benchmark 2.8 times slower. `memset` used 63 percent of executed instructions. | [Measured workaround](https://github.com/ghostty-org/ghostty/blob/09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8/src/quirks_memset.zig#L1-L32) | Inspect bbr's ReleaseFast profile and disassembly because bbr also uses Zig 0.16. First remove large fills where possible. Do not add a global override without the same evidence. |

## Tree-sitter integration findings

The official API and bbr's immutable full-File Highlighting contract support the current full parse and full query shape. They do not support viewport-only or incremental work without changing that contract.

| Practice | Decision for bbr | Evidence |
|---|---|---|
| Parse a contiguous buffer with `ts_parser_parse_string`. | Keep. File Enrichment already owns one contiguous blob. A custom `TSInput` callback adds no data-layout benefit. | [Pinned API](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L281-L348), [official basic parsing guide](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/2-basic-parsing.md) |
| Reuse an edited old tree for incremental parsing. | Do not add. Old and new File sides are immutable revisions. bbr does not have the exact `TSInputEdit` sequence that the API requires. | [Pinned API](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L281-L290) |
| Cache `TSQuery` objects. | Add one immutable query package per Grammar. Include the highlight query, any locals query, validated predicate data, RE2 objects, and Capture names. | [Official query API](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/queries/4-api.md), [RE2 thread safety](vendors/re2/re2/re2.h#L292-L304) |
| Reuse parsers and query cursors. | Give each active Highlighting call exclusive ownership. Never share one global parser or cursor between workers. Add a pool only if setup time is material. | [Official query API](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/queries/4-api.md) |
| Keep each `TSTree` call-local. | Keep. A tree is not thread-safe unless the caller copies it. bbr deletes each tree before the call returns. | [Pinned API](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L401-L412), [current lifetime](src/highlight/tree_sitter_highlighter.zig#L103-L107) |
| Restrict queries to visible ranges. | Do not add under the current Highlighter contract. Range calls return intersecting matches, and non-local patterns reduce range optimization. WholeFile display and Review Search need complete File Spans. | [Range semantics](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L1089-L1155), [non-local patterns](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L970-L978) |
| Use included parser ranges. | Do not use for Diff hunks. A Grammar can need syntax outside a hunk to classify a Capture correctly. Included ranges fit embedded-language regions, not partial syntax coloring. | [Official advanced parsing guide](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/3-advanced-parsing.md) |
| Set a finite query match limit. | Add only as a measured tail guard. Tree-sitter silently drops an early match when it exceeds the limit. Reject the complete Highlighting result when `did_exceed_match_limit` is true. | [Pinned API](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L1074-L1087), [current rejection](src/highlight/tree_sitter_highlighter.zig#L145-L162) |
| Use progress callbacks. | Consider a deadline for pathological Files. A callback can cancel work, but bbr's synchronous Highlighter cannot yield a useful partial result. Call `ts_parser_reset` before using a cancelled parser for another File. | [Pinned API](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L305-L373) |
| Override Tree-sitter allocation. | Do not use per-worker arenas. The allocator hook is process-global, and the default allocator aborts on failure. Use an override only in an isolated benchmark or through a process-wide design. | [Pinned API](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L1439-L1464) |
| Use `next_match` for highlight Captures. | Keep. bbr needs the pattern index for predicates and later-pattern precedence. `next_capture` alone does not remove that work. | [Cursor result ordering](vendors/tree-sitter/runtime/include/tree_sitter/api.h#L1031-L1050), [current loop](src/highlight/tree_sitter_highlighter.zig#L145-L160) |

Caching adds one concurrency and lifetime prerequisite. `Registry.grammar` can load a UserGrammar lazily and mutate `installation.loaded`. Concurrent first use has no synchronization. [Source](src/highlight/user_grammar.zig#L242-L280). Load and freeze active UserGrammars before workers start, or protect initialization. A cached query must be deleted before its UserGrammar dynamic library closes.

## Action table

The order below puts measurement and bounded worst-case work before layout changes. "Gain" names the expected type of gain, not an unmeasured speedup.

| Order | Action | Gain | Effort | Risk | Required proof |
|---|---|---|---|---|---|
| 0 | Add `zig build bench` with ReleaseFast headless benchmarks and stage timers. Record median, p95, allocation count, peak bytes, retained bytes, and output checksums. Keep fixture generation outside timing. | Evidence for every later action | Medium | Low | Repeat fixed inputs serially with warmups. Compare separate binaries from the same machine. |
| 1 | Bound SideBySide matching by replacement-block area and per-Line token product. Fall back to index pairing or whole-Line emphasis when a limit is exceeded. Reuse one bounded scratch workspace for token and LCS arrays. Do not pass the Buffer arena directly because per-pair frees would retain every temporary allocation. | Bounded worst-case latency and fewer allocator calls | Medium | Low to medium. Only cosmetic pairing changes at the limit. | Benchmark `10x10`, `100x100`, and `500x500` replacement blocks. Include short, long, and minified Lines. Assert exact reconstruction and stable pairing below the limit. |
| 2 | Split the Highlighter's scratch allocator from its result allocator. Release Highlighting scratch after each side while retaining only the blob and final Spans. Add a retained-capacity limit for Buffer and frame arenas after unusually large reviews. | Lower retained memory | Medium | Medium. Ownership rules cross the Highlighter seam. | Measure peak and retained bytes at 4 KiB, 100 KiB, 1 MiB, and 2 MiB for every BuiltInGrammar. |
| 3 | Build one immutable runtime package per Grammar. Cache the highlight `TSQuery`, any locals `TSQuery`, predicate tables, RE2 objects, and Capture names. Freeze or synchronize UserGrammar loading. Keep parsers and cursors call-local at first. | Less repeated Highlighting setup | Medium | Medium. Query and dynamic-library lifetimes must have one clear owner. | Time cold setup, warm parse, locals query, highlight query, predicates, Span construction, and total. Run concurrent first-use stress tests. |
| 4 | Replace per-byte Capture labels with a precedence-preserving interval sweep. Share Capture names instead of copying one name for each Span. | Lower peak memory and fewer byte writes and small allocations | Medium to high | High. Overlap precedence and UTF-8 boundaries must remain exact. | Differential-test every Grammar against the current implementation. Include nested, overlapping, predicate-heavy, invalid, and minified input. Compare every output Span byte for byte. |
| 5 | Replace `lineSpans` rescans with monotonic old-side and new-side cursors during Buffer construction. Use binary search if projection order prevents a cursor. | Linear or `O(L log S)` Span access instead of `O(L * S)` | Small | Low | Benchmark a 5,000-Line File with sparse and dense Spans in Unified and SideBySide layouts. |
| 6 | Build contiguous File and line indexes for Threads and root Drafts once per Buffer transaction. Reuse one File tally array in Buffer and File Tree. | Fewer repeated scans and path comparisons | Medium | Medium. Placement and outdated sections must stay identical. | Benchmark 300 Files with 0, 100, and 2,000 Threads and Drafts. Differential-test every emitted row and tally. |
| 7 | Store row-to-File identity or File header ranges in the Presentation Frame. Remove unused `file_tallies` or route them into File Tree. Stop width measurement for unwrapped rows if no consumer needs it. | Lower per-event and per-rebuild work | Small | Low | Benchmark cursor movement near the start and end of a 50,000-row Buffer. Run navigation and mouse hit-test tests. |
| 8 | Retain width-independent `ReviewBody` parses and immutable blob line indexes for one Session. Reproject only width-dependent ReviewCard rows and WholeFile ranges. | Less repeated parsing and splitting | Medium | Medium. Session and Draft mutation must invalidate the right data. | Measure repeated resize, disclosure, Draft-save, and WholeFile rebuilds. Check memory retained by the Session. |
| 9 | Split Buffer, visual-row, and File Tree invalidation only if stage timers show repeated unrelated work. Preserve atomic Presentation Frame publication. | Lower interaction latency | High | High. Partial invalidation can publish inconsistent navigation data. | Record each stage for resize, fold, layout, scope, disclosure, Draft, and File Enrichment events. Add transaction-failure tests. |
| 10 | Add parser and cursor pools only if their setup exceeds a material share of warm Highlighting time. Add measured parser deadlines and a query match limit as tail guards. Reject partial Highlighting. | Warm latency or bounded tail latency | Medium | Medium. Pool leases and cancellation reset must be correct. | Compare call-local and pooled warm runs. Test cancellation, `ts_parser_reset`, match-limit failure, and concurrent File Enrichment. |
| 11 | Test compact hot projections only after cache profiles point to them. Candidate changes are a `u32` File index per visual row, compact Capture IDs, and hot navigation arrays that refer to cold Buffer rows. | Better cache density | High | High. Broad model changes can add indirection and memory. | Record `@sizeOf` values, bytes per projected Line, cache misses, and scan time before and after each isolated layout change. |
| 12 | Add SIMD only for a measured simple scan. The first candidates are a printable-ASCII width fast path and compact tag or flag scans. Prefer deleting a scan through an index. Inspect `memset` disassembly before copying Ghostty's Zig 0.16 workaround. | CPU throughput in a proven scan | Medium to high | High. Architecture behavior and tails differ. | Keep a scalar reference. Run differential tests on all lengths, alignments, ASCII controls, UTF-8, and supported targets. Require a ReleaseFast gain. |
| 13 | Measure shared HTTP connection reuse and concurrent old/new side fetches as separate experiments. Keep request bounds and Bitbucket rate-limit behavior visible. | File focus latency | Medium | High. Shared client and worker lifetime rules can fail. | Record first and warm File latency, connection count, failures, and 429 responses. Do not mix this benchmark with CPU benchmarks. |

## Benchmark corpus

Use deterministic generated fixtures and keep generation outside the timed process.

| Fixture | Purpose |
|---|---|
| RawDiff with 300 Files and 50,000 Hunk Lines | Diff parsing, Buffer, visual rows, File Tree, navigation, and retained arenas |
| The same Diff with 0, 100, and 2,000 Threads and Drafts | Placement indexes, tallies, and ReviewCard costs |
| Replacement blocks from `10x10` through `500x500` | SideBySide Line matching and fallback limits |
| Lines with 10 through 4,000 lexical parts | Intra-line LCS time, workspace size, and fallback limits |
| BuiltInGrammar Files at 4 KiB, 100 KiB, 1 MiB, and 2 MiB | Tree-sitter cold and warm phases, peak memory, and retained memory |
| Valid, invalid, minified, and predicate-heavy source | Tree-sitter tail behavior and interval-sweep equivalence |
| Buffers with ASCII, tabs, controls, combining marks, wide glyphs, and invalid UTF-8 boundaries | Cell width and SIMD differential tests |
| Repeated large-review then small-review sequence | Retained arena capacity and release policy |

Run CPU benchmarks without network access. Run live acquisition and File Enrichment transport checks as a separate tier because network variance can hide CPU changes.

## Changes not recommended now

| Change | Reason |
|---|---|
| Incremental Tree-sitter parsing | bbr does not edit one source buffer or own exact edit records. |
| Query only visible hunks | The Highlighter contract, WholeFile display, and Review Search require complete File Spans. Syntax outside a hunk can affect a Capture. |
| Custom chunked `TSInput` | File Enrichment already has a contiguous blob. |
| One global Tree-sitter parser or query cursor | Both objects carry mutable execution state and active workers need exclusive ownership. |
| SIMD in the LCS | LCS cells depend on neighboring cells. Bound or replace the algorithm before considering low-level tuning. |
| SIMD in Tree-sitter traversal | Tree-sitter owns lexing, parsing, and query traversal. Optimize bbr's setup and Span postprocessing. |
| Pack every Diff and Buffer struct | Ghostty packs fixed terminal cells. bbr's Rows carry varied semantic data. Use profiles to identify a hot field subset first. |
| bbr dirty-row rendering | bbr already draws only the viewport and libvaxis controls terminal rendering. Measure draw CPU before adding another state model. |
| A global `memset` override | Ghostty added one for a measured Zig 0.16 regression. bbr needs its own profile and disassembly evidence. |

## Source notes

The Tree-sitter recommendations use the vendored `v0.26.9` API, the official [basic parsing guide](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/2-basic-parsing.md), the official [advanced parsing guide](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/3-advanced-parsing.md), and the official [query API guide](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/queries/4-api.md). These sources were checked on 2026-09-03.

Ghostty findings use source comments and benchmark guidance at the pinned commit. Reported speedups belong to Ghostty's named workloads. They are not forecasts for bbr.
