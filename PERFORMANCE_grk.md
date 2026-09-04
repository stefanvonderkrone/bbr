# BBR performance actions

Rechecked **2026-09-03** against this checkout (`09ffc95` on `performance-plan`). Line numbers below are from that tree.

Analysis of **libghostty** (`/Volumes/Work/Github/ghostty`), this repo, and Tree-sitter host best practices. Goal: data-oriented layout, cache-friendly scans, SIMD only where data is dense and uniform. **No code changes in this document.**

BBR is not a 60 Hz terminal engine. The expensive work is **off-frame highlight + on-event full flatten/wrap/paint**. Ghostty’s lessons still apply: own a cell buffer, invalidate narrowly, keep hot structs small and SoA, intern strings, reuse parsers.

There is still **no** `src/benchmark/` and **no** `@Vector` / `std.simd` in first-party `src/`.

---

## Recheck notes (what changed vs the first draft)

| Claim in first draft | Status now |
| --- | --- |
| Tree-sitter: new parser/query every highlight, `u32` label planes, `dupe` capture names | **Unchanged.** `highlightWithQueryLimit` still does all of this. |
| `parse_string(..., null, ...)` for blobs | **Still correct.** Keep it (A5). |
| Event loop always paints | **Unchanged.** `app.zig` 150–236: every event → `drawReview` / overlays → `vx.render`. |
| Cursor/scroll always `prepareBuffer` | **Too strong.** `prepareBuffer` runs on rebuild/resize/draft/enrichment (`presentation.zig` 1407–1723, 4111), not on `scrollPane` (4292). Cursor/scroll still **full paint** + **`fileIndexForRow`**. |
| `matchingSimilarity(page_allocator)` in SBS DP | **Unchanged.** `buffer.zig` 706. |
| `lineSpans` restarts at 0 | **Unchanged.** Cursor is local to the call (`842–860`). |
| `weaveInline` nested loops | **Unchanged.** `794–811`. |
| `disclosureExpanded` linear | **Unchanged.** `223–226`. |
| `VisualRow` embeds full `Row` | **Unchanged.** `frame.zig` 84–94. |
| `win.clear` / per-cell `fillRow` / `readCell` cursor | **Unchanged.** `render.zig` 71, 88, 1075–1079, 315–323. |
| Gutter `allocPrint` | **Unchanged.** `numCol` 1070–1072; callers 291–293, 346–348. |
| `fileIndexForRow` linear tag scan | **Still present, previously under-specified.** Two copies: `presentation.zig` 6714 and `app.zig` 1161; event loop calls it every frame (`app.zig` 194). |
| `CellMetrics` vtable per grapheme on wrap | **Unchanged.** `cell_metrics.zig` 27–36; `app.zig` 284–288. |

---

## Context (what each source actually does)

| Source | What matters |
| --- | --- |
| **Ghostty** | VT + renderer are SoA cell grids (`back`/`front`), dirty tracking, grapheme intern, SIMD on **row-shaped** data, GPU **instanced** quads. Tree-sitter is on-demand / viewport, not a full-file per-byte map. |
| **BBR** | Git blob + unified diff → parse once → worker highlight → UI rebuilds fat `Row[]` + wrap-all `VisualRow[]` on layout/scope/enrichment; **every input event** clears and paints. No first-party SIMD. Tree-sitter: new parser/query every file, `u32` label planes of `content.len`. |
| **Tree-sitter** | Official shape is `HighlightConfiguration` **once per language**, `Highlighter` **once per thread**, `HighlightEvent` spans. Queries are immutable and shareable. Parsers/cursors are **not** thread-safe. Incremental `old_tree` is for **edits**; git blobs should keep `parse_string(..., NULL)`. |

---

## Action table (do these, in this order)

| ID | Pri | Area | Action | Why (BBR today) | Ghostty / TS analog | SIMD? |
| --- | --- | --- | --- | --- | --- | --- |
| A0 | P0 | Measure | Add a `src/benchmark/` harness (synthetic large diff, minified pair, fat TSX, many-file PR) before layout rewrites | No in-repo CPU/memory benches | Ghostty `src/benchmark/` | — |
| A1 | P0 | Highlight | Compile `TSQuery` (highlights **and** locals) **once per grammar**; cache `#match?` / RE2 predicates with the query | `ts_query_new` + `Set.validate` every `highlightWithQueryLimit`; locals compile again in `Locals.collect` | `HighlightConfiguration` at language load | No |
| A2 | P0 | Highlight | Own **one `TSParser` + one `TSQueryCursor` per enrichment worker**; `set_language` on switch; never share parser across threads | `ts_parser_new` / `cursor_new` / `delete` per file (and again for locals) | Per-thread highlighter; query objects shared | No |
| A3 | P0 | Highlight | Store `Span.capture` as **query capture id (`u16`)**, intern names once; theme = **id → color table**, not `mem.eql` on strings | `capture_name_for_id` + `dupe` per span; `captureColor` does prefix `eql`s | Ghostty intern pool; TS `capture.index` | No |
| A4 | P0 | Highlight | Replace per-byte `u32` label + priority planes with **interval merge** `{start,end,id}` then split on `\n` | Peak **16 bytes × file size** + O(bytes × overlapping captures) | Host emits events/spans, not byte maps | Maybe later on newline scan only |
| A5 | P0 | Highlight | **Keep** `ts_parser_parse_string(parser, null, …)` for blobs; do **not** add `ts_tree_edit` | Blobs are immutable new documents | Official first-parse / unrelated-doc path | No |
| A6 | P0 | Draw | Cursor/scroll already skip `prepareBuffer`. Next: skip **full-screen paint** where possible; at least stop **`fileIndexForRow` every event** (A23) | Event loop always `drawReview` + `vx.render` | Ghostty dirty/viewport | After A14 |
| A7 | P0 | Rebuild | Index comments/drafts by `(path, line)`; **monotonic span cursor** in `lineSpans`; **set/hash** for expanded disclosures | Nested `weaveInline`; `lineSpans` local `first = 0`; linear `disclosureExpanded` | SoA + indexed lookups | No |
| A8 | P0 | Rebuild | Cache intra-line LCS / emphasis on the hunk or enrichment side; **stop** `page_allocator` in side-by-side DP — use buffer/scratch arena; **cap** token/table size | `matchingSimilarity(page_allocator)` per removed×added pair; `commonTable` is `O(T_old * T_new)` `usize` cells | Allocate in generation arena | Bit-LCS only if profiled hot |
| A9 | P0 | Draw | Paint gutters from **stack `[N]u8`**, not `allocPrint` per column | `numCol` → `allocPrint("{d: >4}")` twice per visible line | Fixed-width fields | No |
| A10 | P0 | Draw | Apply cursor-row style **while drawing**; never `readCell`+`writeCell` the whole row. Prefer one `printSegment` of spaces over per-column `fillRow` | `highlightCursorRow` re-walks cells; `fillRow` is one `writeCell` per column | Style is data on the cell | After owning a cell row (A14) |
| A11 | P1 | Layout | Split `Row`: `kinds: []RowKind` + compact payloads. **`VisualRow` must not embed a full `Row`** | Fat tagged unions copied into wrap list | Ghostty page SoA | Enables later SIMD equality |
| A12 | P1 | Layout | Decode **grapheme width once** per line into `[]u8`; ASCII fast path (`byte >= 0x80` vector) then wrap scans that stream | `CellMetrics` vtable on every wrap of **all** rows | Ghostty `@Vector` ASCII early-exit | Width: ASCII vector; wrap later |
| A13 | P1 | Invalidation | Wrap **viewport** (plus overscan) **or** cache wrap until width/wrap-mode/buffer generation changes | `buildVisualRowsWithOptions` wraps the entire buffer on every `prepareBuffer` | Viewport-sized work | No |
| A14 | P1 | Draw | Optional: own a **SoA cell row** and blit to vaxis once; skip `win.clear()` if every cell is written | `win.clear` + nested `writeCell` borders | Ghostty front/back | **Yes**: row clear / dirty compare |
| A15 | P1 | Highlight | Cache highlight **results** by `(grammar, blob identity)` on the session | Re-enrich / both sides can re-parse the same bytes | Content-addressed cache | No |
| A16 | P1 | Highlight | Build a **line-start index `[]u32`** when the blob is admitted | Highlighter and whole-file buffer both walk `\n` | Dense prefix array | `indexOfScalarPos` / `@Vector` |
| A17 | P2 | Draw | Dirty regions: sidebar vs diff vs overlay; use `frame_revision` as **skip-draw**, not only identity | Revisions exist; every event still paints | Ghostty dirty bits | SIMD memcmp if A14 exists |
| A18 | P2 | Highlight | Range-limited query (`set_byte_range`) only if still hot after A1–A4 | Full-file cursor exec; cap is `maxInt(u32)` | Viewport highlight in editors | No |
| A19 | P2 | SIMD | After A11/A14: vectorized **row fill, style splat, row equality** | No `@Vector` in `src/` | Ghostty `simd.zig` | **Primary SIMD surface** |
| A20 | Skip | SIMD | Do **not** SIMD the Tree-sitter C parser | Table-driven lexer; not your data | Upstream TS | Skip |
| A21 | Keep | Alloc | Keep `ArenaRing(2)` + `retain_capacity` frame arena + zero-copy diff `Line.text` + off-thread enrich | Already the right lifetime model | Ghostty page arenas | — |
| A22 | Skip | TS | Injections, chunked `TSInput`, caching `TSTree` across blob identity changes | Contiguous immutable blobs | Optional in `tree-sitter-highlight` | Skip |
| A23 | P0 | Event | Store `file_index: u32` (or header ranges) on each buffer/visual row; delete the linear scans | `fileIndexForRow` walks union tags from row 0; used from the event loop and many Presentation paths | Ghostty precomputed offsets | Tag array is `@Vector`-scannable later |

---

## Suggested sequence

1. **A0** — measure, or you cannot rank A8 vs A1.
2. **A1–A4, A3** — cheapest large-file win; drop query compile and byte planes.
3. **A8, A7, A23** — rebuild and per-event scans.
4. **A6, A9–A10** — paint without per-cell and per-gutter allocs (cursor already skips rebuild).
5. **A11–A14, A12** — SoA rows and optional cell buffer (this is when SIMD becomes real).
6. **A15–A19** — result cache, line index, dirty rows; measure before bit-LCS or newline SIMD.

---

## Explicit non-goals

- Incremental Tree-sitter edits (`ts_tree_edit`) for git blobs.
- Porting Ghostty’s GPU glyph atlas / Metal path into the TUI.
- SIMD inside vendored Tree-sitter / RE2.
- App-level terminal dirty tracking **before** measuring draw vs projection (vaxis already diffs cells).

---

## Current line index

| Topic | File:lines |
| --- | --- |
| Event loop full paint | `src/tui/app.zig` 150–236 |
| Frame arena reset | `src/tui/app.zig` 145–146, 236 |
| Per-event `fileIndexForRow` | `src/tui/app.zig` 194, 1161–1170 |
| Grapheme vtable | `src/tui/app.zig` 284–288; `src/tui/cell_metrics.zig` 8–36 |
| `dispatch` (no rebuild here) | `src/tui/presentation.zig` 2889–2936 |
| `prepareBuffer` + wrap-all + tree | `src/tui/presentation.zig` 1669–1723 |
| `rebuild` | `src/tui/presentation.zig` 1407–1416 |
| Resize rebuild | `src/tui/presentation.zig` 4105–4115 |
| Presentation `fileIndexForRow` / header scans | `src/tui/presentation.zig` 6714–6752 |
| `win.clear` | `src/tui/render.zig` 71, 88 |
| Per-cell fill / cursor | `src/tui/render.zig` 1075–1079, 315–323 |
| Gutter `numCol` | `src/tui/render.zig` 1070–1072, 291–293, 346–348 |
| `captureColor` | `src/tui/theme.zig` 176–192 |
| `ArenaRing` | `src/tui/arena_ring.zig` 20–61 |
| `Row` union | `src/tui/buffer.zig` 146–157 |
| `disclosureExpanded` | `src/tui/buffer.zig` 223–226 |
| `page_allocator` LCS | `src/tui/buffer.zig` 695–707 |
| `weaveInline` | `src/tui/buffer.zig` 794–811 |
| `lineSpans` | `src/tui/buffer.zig` 841–860 |
| `VisualRow` | `src/tui/frame.zig` 84–94 |
| Wrap entry | `src/tui/frame.zig` 192 |
| Diff `Line` | `src/diff/model.zig` 18–31 |
| Intra-line DP table | `src/diff/intraline.zig` 66–83, 104–140, 159 |
| Highlight seam / `Capture.name` | `src/highlight/highlighter.zig` 8–23, 43–54 |
| TS parse + labels + dupe | `src/highlight/tree_sitter_highlighter.zig` 100–198 |
| Locals `ts_query_new` | `src/highlight/query_predicates.zig` 53–71 |
| Enrich + side arena | `src/tui/file_enrichment.zig` 130–194 |

Measure after each P0 band with a large PR (multi-MB diff, dense comments, wrap on) before starting SIMD work.
