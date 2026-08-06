# Choose the Markdown projection seam

Type: grilling
Status: resolved
Blocked by: 04

## Question

What Presentation-owned intermediate representation should parse raw Comment and Draft bodies into width-independent Markdown blocks, project those blocks into width-dependent Buffer rows, preserve row-to-item ownership and semantic block boundaries, and compose Markdown styles with Comment, Draft, Suggestion, focus, and Theme roles without leaking presentation state into Review?

## Answer

Use a two-stage, Presentation-owned `ReviewBody` → `ReviewCardRow` projection and make the pure projection layer an explicit `bbr.presentation` package.

### Ownership and module boundary

- Move `Buffer` and its builder from `bbr.diff.buffer` into the network-free `bbr.presentation` package. Keep Diff limited to Files, Hunks, Lines, Folds, and intra-line data; keep `src/tui/render.zig` as the vaxis adapter. Do not move the whole TUI state machine as part of M15.
- Review continues to own the authored Comment and Draft body bytes unchanged. Presentation alone interprets those bytes and owns all Markdown, wrapping, card, disclosure, geometry, and style-role state.
- Reparse each body into the buffer-scoped arena on every Buffer reconstruction. Do not add a Session cache until profiling justifies its ownership and invalidation cost.

### Width-independent `ReviewBody`

- Parse into typed blocks: paragraph, ATX heading (retaining level), Suggestion, literal, and source-derived spacer. Paragraphs and headings contain spans with composable emphasis, strong, link-label, and link-destination marks. Every block and span retains its source byte range.
- Support only one-to-six `#` ATX headings followed by whitespace, paired `*`/`_` emphasis, paired `**`/`__` strong, inline `[label](destination)` links, backslash escapes for supported punctuation, and line-oriented triple-backtick fences whose trimmed info string is exactly `suggestion`. Setext headings, images, reference links, lists, quotes, tables, HTML, inline code, and general CommonMark constructs remain literal in M15.
- Render headings as the selected bounded-card prototype's strong `§` section rows. Render a link as its styled label followed by a visible `‹destination›`. Suggestion contents are literal and never recursively parsed as Markdown.
- Discard leading and trailing blank lines. Collapse one or more blank source lines between ordinary blocks to one owned spacer row; preserve blank lines inside Suggestions exactly. Every projected spacer and Suggestion blank line counts toward disclosure.
- Recover locally and visibly: unmatched or malformed inline delimiters keep their punctuation; unsupported constructs become literal blocks without disabling supported syntax elsewhere. An unclosed Suggestion fence is the sole whole-body literal fallback. Invalid UTF-8 projects one replacement glyph per invalid sequence while Review retains the original bytes. Allocation failure aborts reconstruction rather than publishing partial content.

### Width-dependent rows

- Replace parallel `CommentRow` and `DraftRow` shapes with one `ReviewCardRow`. It carries a tagged stable owner (`CommentId` or `TempId`), a borrowed tagged reference to the source item, card part (header, body, Suggestion label/body, disclosure footer), reconstruction-local block ordinal and kind, source range, and semantic text segments. Concrete colors and vaxis styles never enter the row model.
- Inject a small `CellMetrics` interface that returns the next complete UTF-8 grapheme's byte length and terminal-cell width. The TUI adapter implements it with the pinned libvaxis grapheme iterator and active width method. Prefer whitespace wrap points and split overlong tokens only at grapheme boundaries. The renderer prints the already-wrapped segments with wrapping disabled.
- Compute terminal columns and rows through one pure, Presentation-owned `FrameGeometry`. It is the shared authority for Sidebar, DiffPane, borders, gutters, and inner widths; Buffer projection and vaxis rendering consume the same value. Card width accounts for marker and reply indentation. Even a pathologically narrow Pane supplies at least a one-cell content width and uses grapheme-safe clipping.

### Disclosure and restoration

- A collapsed ReviewCard emits at most the configured body-row limit, six by default. This is a hard limit across all block kinds: paragraphs, headings, and Suggestions may cross the disclosure boundary. The visible and hidden halves retain the same semantic block metadata and styling; block boundaries inform interpretation, not atomic disclosure.
- The header and disclosure footer do not count toward the body budget. The footer remains owned by the same stable item and reports hidden and total projected rows at the current width. Expansion state remains Session-relative and external to `ReviewBody`, keyed by tagged `CommentId`/`TempId` as decided in [Choose Markdown and long-body presentation](04-choose-markdown-and-long-body-presentation.md).
- Before reconstruction, capture a logical cursor anchor. A card header/footer records owner plus exact part; a body row records owner plus its starting source offset. A synthesized visible link destination anchors to the source link range. Restore to the same owner's row containing, or nearest after, that source offset. If collapsing hides the selected content, land on that card's disclosure footer. Clear visual Selection whenever reconstruction changes its row range.
- Stage Buffer and `FrameGeometry` together. A resize, disclosure toggle, File isolation, or other rebuild publishes both atomically; failure preserves the previous matching Buffer/geometry pair and navigation.

### Theme composition and acceptance matrix

- Resolve styles centrally in `Theme`: card role establishes the Comment/reply/Draft/Draft-reply/outcome surface; row part refines header, prose, heading, Suggestion, or footer; inline marks add emphasis/strong/link treatment without erasing the surface; focus applies last while preserving semantic foregrounds and attributes. Suggestion may replace the ordinary body surface because it is the stronger semantic role.
- Add deterministic tests for the supported grammar and literal recovery; closed/unclosed Suggestions; whitespace normalization; nested composable marks; visible links; invalid UTF-8; ASCII, combining, CJK, emoji, whitespace, and overlong-token wrapping through `CellMetrics`; zero/narrow widths; the six-row hard boundary through paragraphs, headings, Suggestions, and spacers; exact hidden/total counts; stable owner/source ranges; Comment/Draft parity; Theme-role precedence; source-offset cursor restoration on resize and toggle; selection clearing; and atomic Buffer/geometry rollback on allocation or projection failure.

## Comments

- 2026-08-06: Compared whole-block, mixed-boundary, and hard-limit disclosure policies in the interactive prototype on branch `prototype/m15-markdown-disclosure-boundaries`, commit `50de392`, path `.scratch/m15-presentation-navigation-polish/prototypes/markdown-disclosure-boundaries/`. The human selected **C — Hard limit · split all blocks**: a collapsed body emits at most six projected rows even when that boundary crosses a heading or Suggestion; semantic block metadata and styling remain intact on both sides of the boundary.
