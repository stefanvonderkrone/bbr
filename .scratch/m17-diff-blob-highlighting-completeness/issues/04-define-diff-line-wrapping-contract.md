# Define the DiffPane line-wrapping contract

Type: prototype
Status: resolved
Blocked by: 03

## Question

How should the user-toggleable DiffPane word-wrapping mode project long Diff Lines into visual rows while preserving diff styling, Unified/SideBySide boundaries, cursor and Selection navigation, comment Anchors, folds, and the current clipped presentation when disabled?

## Answer

- Add a `toggle_diff_wrap` Action, bound to `w` by default and available to Keymap configuration. Wrapping is a Presentation preference with the same lifetime as Layout and Scope: it survives Buffer rebuilds and Session replacement within the process. It starts disabled on each launch, preserving the current clipped presentation.
- Reproject only Diff `Line` and `LinePair` rows at the current DiffPane geometry. File and Hunk headers, Folds, Status Placeholders, sections, and ReviewCards retain their own one-row or existing width-projection contracts.
- Split text by terminal display-cell width without changing source bytes: prefer the last Unicode whitespace boundary that fits, otherwise break at a grapheme boundary. Slice `LineDecoration` runs by source byte range so syntax foreground, IntraLineSegment emphasis, diff background, and Selection styling continue across every visual row.
- In Unified Layout, the first visual row carries both line-number gutters. Continuations use blank gutters. With wrapping disabled, emit one visual row and clip exactly as today.
- In SideBySide Layout, derive each half's body width after its gutter and the fixed divider, then wrap the old and new Lines independently. A `LinePair` occupies the greater continuation count; the shorter or absent side contributes neutral blank cells. The divider never moves, no text crosses it, and the side-by-side matching decision remains unchanged.
- Treat each continuation as a navigable visual row. `j`/`k`, arrows, Count, paging, viewport motions, cursor highlighting, and scrolling operate on visual rows. Semantic jumps such as File navigation land on the first visual row of their target.
- Give every visual row a stable semantic owner plus its source-byte start. Resizing or toggling Layout, Scope, or wrapping atomically rebuilds the Presentation Frame and restores the cursor to the visual row containing the previous source offset, with nearest-following then final-row fallback. Preserve the prior complete Frame if reprojection fails.
- Selection remains semantic: endpoints resolve to underlying Diff Lines, repeated continuations are deduplicated, and all visual rows of each selected Line show the Selection style. Existing mixed-side, hunk-gap, and non-Anchor-target refusal rules remain unchanged. A comment or Suggestion from any continuation uses the underlying Line's existing old/new Anchor; a continuation never creates a new Anchor identity.
- Required coverage: Unified soft and hard wrapping; Unicode wide and combining graphemes; decoration runs crossing wrap boundaries; clipped parity when disabled; unequal and absent SideBySide halves; visual-row Motion and Count; Selection within one wrapped Line and across Lines; Anchor creation from a continuation; resize/toggle restoration; folds and Status Placeholders remaining atomic; narrow panes with no body cells; and unchanged Unified/SideBySide semantic Line order.
- Prototype: local branch `prototype/m17-diff-line-wrapping`, commit `c53cd3a`, file `src/tui/diff_line_wrapping.prototype.html`. The walkthrough compared visual-row and semantic-Line navigation; the selected contract is visual-row navigation.
