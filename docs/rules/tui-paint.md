# TUI paint rules

This document holds the checked rules that decide what a terminal cell of the TUI shows. The parts that no check covers are in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

## Selected Version marker columns

A SideBySide Selected Version marker sits left of its column and leaves the text intact. The old version marker has its own column. That column is the `version_marker` Slot between the DiffPane border and the body in `layouts.panes`, so the marker never shares a cell with the Anchor Indicator. Unified rows have no Selected Version marker.

Enforcement: the tests "Selected Version markers stay left of their SideBySide column and off Unified rows" and "the old version marker and the Anchor Indicator keep separate columns" in `src/tui/render.zig`, run by `zig build test`.

## One built-in Theme for each ThemeId

Each `ThemeId` has one built-in Theme with the same name.

Enforcement: the `comptime` block after `theme.value` in `src/tui/theme.zig` (compile error), and the tests in `src/tui/theme.zig`, run by `zig build test`.

## View trees and the painter

A terminal surface is a View tree in `src/tui/layouts.zig`. Only `src/tui/view_paint.zig` paints borders, rules, junctions, Titles, and scroll bars. A content painter draws into the content rect of a Slot.

Enforcement: `tools/check_box_glyphs.py`, run by `zig build test`. It rejects a border corner or junction glyph in `render.zig` or `app.zig` outside `test` blocks. The tests in `tests/check_box_glyphs_test.py`, run by `zig build test`, check the validator.

## Pane borders and Titles

A Pane has rounded corners and its Title in the top border. Its body starts in the next row, with no rule under the Title. The Sidebar and the DiffPane touch, with no empty column between them.

Enforcement: the test "focused Pane frames and File Tree tallies use Frame-owned geometry" in `src/tui/render.zig` and the tests in `src/tui/layouts.zig`, run by `zig build test`.

## Title gaps

Every Title has one blank cell on each side, so its text never touches the border. A Title that a View tree cannot hold, such as the DiffPane path, goes through `view_paint.titleText`. A control that its owner paints, such as the Selected Version control, calls `view_paint.titleGaps`.

Enforcement: `view_paint.titleText` and `view_paint.titleGaps` add the blank cells and take no option to drop them. The tests in `src/tui/view_paint.zig` and the test "DiffPane title reserves and renders published Selected Version targets" in `src/tui/render.zig` check the gaps. `zig build test` runs them.

## Overlay borders

Every Overlay surface has a rounded border. A border has no square option. An input Overlay builds its surface with `inputSurface` in `src/tui/layouts.zig`. Every List Overlay and Review Search is an input Overlay. That surface is a bordered input box above a bordered result box, with no outer border. Every other Overlay builds its surface with `overlaySurface`.

Enforcement: `view.Border` has no corner field (compile error). The tests "every Overlay surface has a rounded border" and "an input Overlay is a bordered input box above a bordered result list" in `src/tui/render.zig`, run by `zig build test`.

## Overlay background

An Overlay paints the base background of the Theme. Only content highlights carry their own background. Examples are the selected entry, search marks, and the diff and ReviewCard bands.

Enforcement: the `comptime` block after `theme.value` in `src/tui/theme.zig` (compile error). The test "every Overlay paints the Theme base background" in `src/tui/render.zig`, run by `zig build test`.

## Compositions

A new Composition is one arm of the `Composition` union in `src/tui/view.zig`.

Enforcement: the exhaustive switch in `view.walk` (compile error).

## Slot placement

A layout tree places each of its Slots exactly once.

Enforcement: the assertions in `view.Solver`, and the tests in `src/tui/layouts.zig`, run by `zig build test`.

## Status style

The status paints each part through `Theme.statusStyle` in `src/tui/theme.zig`. Every cell has the status bar background. The bar follows the Theme polarity. A dark Theme has a dark bar with light text. A light Theme has a light bar with dark text. A new part is one arm of `StatusPart`.

Enforcement: the exhaustive switch in `Theme.statusStyle` (compile error). The tests "the status follows the Theme polarity and emphasizes its parts" and "the status colors each Reviewer Verdict, Buffer Search miss, and busy state" in `src/tui/app.zig`, run by `zig build test`.

## Status layout

The status region is the meta part above the hint part. Each part wraps by item, never inside an item. Its height comes from `layouts.statusHeight` in `src/tui/layouts.zig`. `syncContentGeometry` in `src/tui/app.zig` sends Presentation the content geometry that remains. The position item takes the width of `total/total`, so a cursor move never changes the height.

Enforcement: the tests in `src/tui/layouts.zig`, and the tests "the status puts the meta items above the hint items and separates items on one row", "the status height does not change when only the cursor moves", and "content geometry leaves the rows the status needs" in `src/tui/app.zig`. `zig build test` runs them.

## ReviewCard border and Titles

A ReviewCard has a rounded border with its Title in the top border. Its disclosure footer is the Title in the bottom border. `drawReviewCard` in `src/tui/render.zig` maps each `review_card.Part` to a `view_paint.CardEdge`, and `view_paint.cardEdge` paints it.

A card on the Active Path paints its border, Title, joins, and the rails that lead down to a path card in the border style of its role. Every other card paints them in `Theme.card_border_dim`.

Enforcement: the exhaustive switches in `drawReviewCard` and `Part.isBorder` in `src/tui/review_card.zig` (compile error for a new Part). The `M23 ancestry` tests in `src/tui/render.zig`, run by `zig build test`.

## ReviewCard Anchor Indicator

The Active Path is the card that holds the cursor and its ancestors. Only the thread root of the Active Path has an Anchor Indicator. The indicator runs in column 0 from `╭` on the top anchored Diff Line of the root to `╰` on the top border row of the root. It covers every row between, such as other cards and other anchored lines. The top-left corner of the root in column 1 becomes `┬`. `Buffer.activePath` in `src/tui/buffer.zig` names the rows. `view_paint.anchorIndicator` and `view_paint.anchorCorner` paint them.

A cursor outside a card shows no indicator. A Reply, a File-level card, and a Review-level card have no indicator.

Every card starts one column right of its depth indent, so column 0 stays free for the indicator. `CardIndentation.offset` adds `frame.anchor_cols`, and each gutter starts at `frame.anchor_cols`.

Enforcement: the `M23 ancestry` tests in `src/tui/render.zig`, run by `zig build test`.

## ReviewCard Reply joins and sibling rails

A Reply starts directly below the preceding card, with no blank row. `drawReviewCard` uses `view_paint.join`. The border row directly above the Reply gets `┬`, or `├` on a `╰` corner. The top-left corner of the Reply becomes `├`. A cell that holds no line, such as a disclosure footer Title, stays as it is. A join cell keeps the style of the border that holds it. So a `┬` on an Active Path card stays in the normal border style when its Reply is dim.

A card with a later sibling keeps its line down to that sibling. `drawReviewCard` joins the bottom-left corner of the card with `├`. `view_paint.rail` paints `│` in that column on every row between the card and the sibling, only in a blank cell. `indexCards` in `src/tui/buffer.zig` sets `ReviewCardRow.sibling_below` and `ReviewCardRow.rails` after it weaves.

Enforcement: the exhaustive switches in `drawReviewCard` and `Part.isBorder` in `src/tui/review_card.zig` (compile error for a new Part). The `M23 ancestry` tests in `src/tui/render.zig`, run by `zig build test`.

## Resolved Thread header

A resolved Thread header is the exception to the dim border outside the Active Path. Its rule or root top border stays bold green. The expanded root header replaces the collapsed disclosure row and keeps its disclosure identity.

Enforcement: the `M23 ancestry` tests in `src/tui/buffer.zig` and `src/tui/render.zig`, and the test "Session disclosures toggle independently persist through rebuilds and reset atomically" in `src/tui/presentation.zig`. `zig build test` runs them.

## ReviewCard background

A ReviewCard paints the base background of the Theme on every row, for every CardRole. This covers borders, Titles, body, and footer. A role differs from another role only by its foreground and emphasis. Only content highlights carry their own background. These are the code and Suggestion rows that `Part.hasCodeBackground` names, search marks, and the cursor band.

Enforcement: the `comptime` block after `theme.value` in `src/tui/theme.zig`. Its compile error names the Theme, the role, and the Part, or the field `card_border_dim`. The test "a ReviewCard paints the Theme base background" in `src/tui/render.zig` and the tests in `src/tui/theme.zig`, run by `zig build test`.

## Ancestry Band

When the cursor is in a ReviewCard, only the anchored Diff Lines of its thread root carry the Ancestry Band from `Theme.ancestryBg`. Parent Comments and Drafts keep their normal background. `ActivePath.banded` in `src/tui/buffer.zig` names the rows. It reads the same `Buffer.activePath` that decides the Anchor Indicator and the border styles. The card of the cursor keeps the stronger cursor band.

Enforcement: the `M23 ancestry` tests in `src/tui/render.zig` and the tests in `src/tui/theme.zig`, run by `zig build test`.
