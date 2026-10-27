# One View type with a Composition union lays out the terminal

The terminal UI had hand-written geometry in `frame.zig` and hand-written borders, dividers, and a scroll bar in `render.zig`. Each Overlay centered its own box and counted its own row offsets. We will lay out every surface with one `View` type. A View has the box model of CSS: margin, an optional border, padding, and content. One tagged-union field, the Composition, places the child Views inside the content box. The Compositions come from Every Layout: flow, cluster, repel, sidebar, switcher, grid, reel, and center (which also does the work of a wrapper).

## Decision

- `src/tui/view.zig` owns `Rect`, the box model, the `Composition` union, and `walk`. It imports only `std`. It does not allocate.
- `src/tui/layouts.zig` owns the View tree of each surface: the Panes, the status, each Overlay, and Review Search. A tree is a function `fn (params, area, visitor) void`. The tree lives on the stack of that function, and `walk` visits each View once with its placed rings.
- `view.solve` collects the rects of the named Slots. Presentation, `frame.hitTest`, and `app.zig` read these rects.
- `src/tui/view_paint.zig` is the only painter of decoration: fill, border, rounded corners, titles, rules, junctions, and scroll bars. Content painters draw only into a content rect.
- A scroll bar sits in the padding, the border, or the margin ring. It never changes the content rect, so a hit target does not move when the content starts to overflow.

## Why one View and not one component per Composition

- A Composition only places children. It paints nothing. A render function per Composition has no work to do, except the decoration that every View shares.
- The box model is the same for every Composition. Separate components must either copy it or nest wrapper components, as `vxfw` does with `Border(Padding(FlexColumn))`. Nesting gives two ways to make padding and a deeper tree for every Pane.
- A rule that joins its parent border (`├`, `┤`, `┬`, `┴`) needs the parent rect. One `walk` over one tree has it.
- Geometry must stay free of vaxis, because Presentation and `hitTest` read the same rects that render paints. `vxfw` widgets fuse layout and paint, and they allocate a Surface for each frame.
- A new Composition is one new arm of the union. Each exhaustive `switch` fails to compile until the arm has its placement. This is the same guard that `ListOverlay` uses.

A comptime tree with a comptime Slot check was also sketched. It needs a second channel for runtime numbers, such as the Review Search orientation and the Help height. A runtime tree on the stack holds those numbers directly. `view.solve` asserts that each Slot is placed exactly once, and each tree has a test that solves it.

## Consequences

- Every Overlay paints the Theme's base background, including its border, input, header, and hint rows. Content highlights keep their backgrounds.
- `paneRects`, `overlayRect`, and `reviewSearchGeometry` in `frame.zig` read their rects from `layouts.zig`. A test compares the Pane and Overlay rects with the previous formulas at every terminal size from 5 to 320 columns. A rect with no cells only has to stay empty.
- Review Search places its divider at 3/10 of the body content width, not 3/10 of the body border width. The Results list keeps one padding column for its scroll bar. These moves are one cell or less.
- The Sidebar and the DiffPane have rounded corners. The rule under their Title row is gone, so each body gains one row.
- Every Title has one blank cell on each side. The Review Search status and Results titles need two more cells before they show.
- Every border has rounded corners, and every Overlay surface has a border. `overlaySurface` adds the border around the Overlay's content box, so each Overlay is two cells wider and taller than before. The loading dialog keeps its 48 by 3 size. List Overlay hit testing reads the entries rect from the layout tree.
- An input Overlay, which is every List Overlay and Review Search, has no outer border. `inputSurface` stacks a bordered input box above a bordered result box. A List Overlay names itself in the Title of its input box, so its query row drops the old prefix, and the surface is two rows taller than before.
- The status is a flow of two clusters: the meta part, with the review identity, above the hint part, with the key hints. Each cluster wraps by item and never inside an item, and app.zig paints a separator in the gap between two items on one row. `layouts.statusHeight` solves the same tree for the rows the status needs, so the content area gets the rest, and Presentation gets the new content geometry when the status text changes its height. The bar follows the Theme polarity, and each part, such as a key, its hint, a ref, or the Reviewer Verdict, gets its own color and weight from `Theme.statusStyle`.
- The Sidebar and the DiffPane show a scroll bar in their right border when their rows overflow.
- `tools/check_box_glyphs.py` fails when code outside `view_paint.zig` writes a border corner or junction glyph in `render.zig` or `app.zig`.
