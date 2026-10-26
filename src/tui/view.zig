//! The box-model layout of the terminal UI. A View is one node of a layout
//! tree: margin, an optional border, padding, and content. Its Composition
//! places the child Views inside the content box. Layout is cell arithmetic
//! only: no vaxis, no Theme, and no allocation. See ADR-0013.

const std = @import("std");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.x and row >= self.y and
            col - self.x < self.width and row - self.y < self.height;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Shrink by `edges`. The leading edge moves first, and no size goes
    /// below zero.
    pub fn inset(self: Rect, edges: Edges) Rect {
        return .{
            .x = self.x +| @min(self.width, edges.left),
            .y = self.y +| @min(self.height, edges.top),
            .width = self.width -| (edges.left +| edges.right),
            .height = self.height -| (edges.top +| edges.bottom),
        };
    }

    fn transpose(self: Rect) Rect {
        return .{ .x = self.y, .y = self.x, .width = self.height, .height = self.width };
    }

    fn along(self: Rect, axis: Axis) Rect {
        return if (axis == .horizontal) self else self.transpose();
    }

    /// The part of `self` that starts `offset` cells along `axis` and is `len`
    /// cells long, clipped to `self`.
    fn slice(self: Rect, axis: Axis, offset: u32, len: u32) Rect {
        const flat = self.along(axis);
        const start: u16 = @intCast(@min(offset, flat.width));
        const size: u16 = @intCast(@min(len, flat.width - start));
        return (Rect{ .x = flat.x + start, .y = flat.y, .width = size, .height = flat.height }).along(axis);
    }
};

pub const Axis = enum { horizontal, vertical };

pub const Edges = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub fn all(n: u16) Edges {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }

    pub fn sides(n: u16) Edges {
        return .{ .right = n, .left = n };
    }
};

/// The kind of line a border, a rule, or a scroll bar thumb is. view_paint.zig
/// maps it to a Theme style, so layout never sees a Theme.
pub const Stroke = struct {
    tone: enum { pane, overlay } = .pane,
    focused: bool = false,
};

/// Every border has rounded corners.
pub const Border = struct {
    stroke: Stroke = .{},
};

/// A background that view_paint.zig fills across the border box.
pub const Fill = enum { surface, header };

pub const Align = enum { start, center, end };

/// Text on a line. A bordered View puts its Title on its own top or bottom
/// border. A rule puts its Title on itself. Any other View puts its Title on
/// the line directly above or below it, such as the border of its parent,
/// across its width and the line cell at each end. The Title takes the style
/// of the line under it.
pub const Title = struct {
    text: []const u8,
    edge: enum { top, bottom } = .top,
    @"align": Align = .start,
    /// Cells between each end of the line and the text.
    inset: u16 = 2,
};

/// The ring of the box model that holds a scroll bar. The scroll bar takes
/// the innermost cell of that ring on the trailing side, so the content rect
/// never moves. A padding or margin ring grows to one cell there when it is
/// thinner. A border ring needs a border.
pub const Ring = enum { padding, border, margin };

pub const Scrollbar = struct {
    ring: Ring,
    axis: Axis = .vertical,
    /// Content cells along `axis`.
    total: usize = 0,
    /// The first visible content cell.
    offset: usize = 0,
    stroke: Stroke = .{ .tone = .overlay },
};

/// The size of a View along one axis, as its parent Composition reads it.
pub const Size = struct {
    basis: Basis = .{ .fill = 1 },
    min: u16 = 0,
    max: u16 = std.math.maxInt(u16),

    pub const Basis = union(enum) {
        cells: u16,
        /// A share, by weight, of the cells that the other Views leave.
        fill: u16,
        /// A part of the content extent of the parent.
        fraction: struct { num: u16, den: u16 },
    };

    pub fn cells(n: u16) Size {
        return .{ .basis = .{ .cells = n } };
    }

    pub fn fill(weight: u16) Size {
        return .{ .basis = .{ .fill = weight } };
    }

    pub fn fraction(num: u16, den: u16) Size {
        return .{ .basis = .{ .fraction = .{ .num = num, .den = den } } };
    }

    fn isFill(self: Size) bool {
        return self.basis == .fill;
    }

    /// The cells this Size asks for out of `extent`. A fill asks for all of it.
    fn want(self: Size, extent: u16) u16 {
        const raw: u32 = switch (self.basis) {
            .cells => |n| n,
            .fill => extent,
            .fraction => |f| if (f.den == 0) 0 else @as(u32, extent) * f.num / f.den,
        };
        return self.clamp(raw);
    }

    fn clamp(self: Size, raw: u32) u16 {
        return @intCast(@min(@max(raw, self.min), self.max));
    }
};

/// How a View places its children inside its content box. Every arm except
/// `leaf` and `rule` places children. None of them paints.
pub const Composition = union(enum) {
    /// No children. A content painter owns the content box.
    leaf,
    /// A line one cell thick across a flow. It runs along the long side of
    /// its rect and joins the lines at both of its ends.
    rule: Stroke,
    /// Children one after the other along `axis` (the Every Layout stack).
    /// Children with a cells or fraction Size get their cells first, in
    /// order. Fill children share the rest by weight. The cross axis stretches.
    flow: struct { axis: Axis = .vertical, gap: u16 = 0 },
    /// Children in rows from the start, wrapped to a new row when the next
    /// child does not fit. A child sizes by cells. A fill Size counts as one cell.
    cluster: struct { gap: u16 = 1, row_gap: u16 = 0, justify: Align = .start },
    /// The first child at the start of the row, the last child at the end,
    /// and the free cells shared between them. Children that do not fit in
    /// one row wrap as a cluster does. Without `wrap` they stay in one row,
    /// and the last children shrink first.
    repel: struct { gap: u16 = 1, wrap: bool = true },
    /// Exactly two children. The side child keeps its width Size, and the
    /// main child takes the rest and keeps at least `content_min` cells.
    /// When both do not fit, `wrap` stacks them; otherwise the side child shrinks.
    sidebar: struct {
        side: enum { start, end } = .start,
        content_min: u16 = 0,
        gap: u16 = 0,
        wrap: bool = true,
    },
    /// Children side by side with equal widths while the content box is at
    /// least `threshold` cells wide and there are at most `limit` children.
    /// Otherwise they stack along their height Sizes.
    switcher: struct { threshold: u16, limit: u16 = 2, gap: u16 = 0 },
    /// As many equal columns as fit at `min_item` cells each, filled row by row.
    grid: struct { min_item: u16, gap: u16 = 1, row_gap: u16 = 0 },
    /// Children side by side at their width Sizes, scrolled by `offset`
    /// cells. A child outside the content box gets an empty rect.
    reel: struct { offset: u32 = 0, gap: u16 = 1 },
    /// Each child at its width and height Sizes, centered on `axes`. A fill
    /// Size takes the full extent. This is also the Every Layout wrapper: a
    /// fill width with a `max`, centered on the horizontal axis.
    center: struct { axes: enum { both, horizontal, vertical } = .both },
};

/// The four rings of one placed View.
pub const Placed = struct {
    margin: Rect = .{},
    border: Rect = .{},
    padding: Rect = .{},
    content: Rect = .{},
    /// The scroll bar track. Empty without a scroll bar.
    track: Rect = .{},
};

pub fn View(comptime Slot: type) type {
    return struct {
        const Self = @This();

        /// The name that `solve` publishes this View's rects under.
        slot: ?Slot = null,
        width: Size = .{},
        height: Size = .{},
        margin: Edges = .{},
        border: ?Border = null,
        padding: Edges = .{},
        fill: ?Fill = null,
        title: ?Title = null,
        scrollbar: ?Scrollbar = null,
        composition: Composition = .leaf,
        children: []const Self = &.{},

        /// Place this View in `area`, its margin box.
        pub fn place(self: *const Self, area: Rect) Placed {
            var margin = self.margin;
            var padding = self.padding;
            if (self.scrollbar) |bar| switch (bar.ring) {
                .padding => growTrailing(&padding, bar.axis),
                .margin => growTrailing(&margin, bar.axis),
                .border => std.debug.assert(self.border != null),
            };
            const border_box = area.inset(margin);
            const padding_box = if (self.border != null) border_box.inset(Edges.all(1)) else border_box;
            var placed: Placed = .{ .margin = area, .border = border_box, .padding = padding_box, .content = padding_box.inset(padding) };
            if (self.scrollbar) |bar| placed.track = track(placed, bar);
            return placed;
        }
    };
}

fn growTrailing(edges: *Edges, axis: Axis) void {
    switch (axis) {
        .vertical => edges.right = @max(edges.right, 1),
        .horizontal => edges.bottom = @max(edges.bottom, 1),
    }
}

/// A vertical track is one column on the right; a horizontal track is one row
/// at the bottom. The horizontal case is the vertical case transposed.
fn track(placed: Placed, bar: Scrollbar) Rect {
    if (bar.axis == .horizontal) return verticalTrack(.{
        .margin = placed.margin.transpose(),
        .border = placed.border.transpose(),
        .padding = placed.padding.transpose(),
        .content = placed.content.transpose(),
    }, bar.ring).transpose();
    return verticalTrack(placed, bar.ring);
}

fn verticalTrack(placed: Placed, ring: Ring) Rect {
    return switch (ring) {
        .padding => if (placed.padding.width == 0) .{} else .{
            .x = placed.content.x +| placed.content.width,
            .y = placed.content.y,
            .width = 1,
            .height = placed.content.height,
        },
        .border => if (placed.border.width == 0) .{} else .{
            .x = placed.border.x + placed.border.width - 1,
            .y = placed.border.y +| @min(placed.border.height, 1),
            .width = 1,
            .height = placed.border.height -| 2,
        },
        .margin => if (placed.margin.x +| placed.margin.width <= placed.border.x +| placed.border.width) .{} else .{
            .x = placed.border.x + placed.border.width,
            .y = placed.border.y,
            .width = 1,
            .height = placed.border.height,
        },
    };
}

pub const Thumb = struct { first: u16, len: u16 };

/// The thumb of a scroll bar along a track of `extent` cells, or null when
/// the content fits.
pub fn thumb(extent: u16, total: usize, offset: usize) ?Thumb {
    if (extent == 0 or total <= extent) return null;
    const len = @max(1, (@as(usize, extent) * extent + total - 1) / total);
    const max_offset = total - extent;
    const first = @min(offset, max_offset) * (extent - len) / max_offset;
    return .{ .first = @intCast(first), .len = @intCast(len) };
}

/// Visit `node` and then each descendant, in tree order, with its placed
/// rings. `visitor.visit(*const View(Slot), Placed)` is called once per View.
pub fn walk(comptime Slot: type, node: *const View(Slot), area: Rect, visitor: anytype) void {
    const placed = node.place(area);
    visitor.visit(node, placed);
    const box = placed.content;
    const children = node.children;
    switch (node.composition) {
        .leaf, .rule => std.debug.assert(children.len == 0),
        .flow => |flow| distribute(Slot, children, box, flow.axis, flow.gap, .own, visitor),
        .cluster => |cluster| wrapRows(Slot, children, box, cluster.gap, cluster.row_gap, cluster.justify, visitor),
        .repel => |repel| placeRepel(Slot, children, box, repel.gap, repel.wrap, visitor),
        .sidebar => |sidebar| placeSidebar(Slot, children, box, sidebar, visitor),
        .switcher => |switcher| if (box.width >= switcher.threshold and children.len <= switcher.limit)
            distribute(Slot, children, box, .horizontal, switcher.gap, .equal, visitor)
        else
            distribute(Slot, children, box, .vertical, switcher.gap, .own, visitor),
        .grid => |grid| placeGrid(Slot, children, box, grid.min_item, grid.gap, grid.row_gap, visitor),
        .reel => |reel| placeReel(Slot, children, box, reel.offset, reel.gap, visitor),
        .center => |center| for (children) |*child| {
            const width = if (center.axes == .vertical) box.width else @min(child.width.want(box.width), box.width);
            const height = if (center.axes == .horizontal) box.height else @min(child.height.want(box.height), box.height);
            walk(Slot, child, .{
                .x = box.x + (box.width - width) / 2,
                .y = box.y + (box.height - height) / 2,
                .width = width,
                .height = height,
            }, visitor);
        },
    }
}

fn mainSize(comptime Slot: type, child: *const View(Slot), axis: Axis) Size {
    if (child.composition == .rule) return Size.cells(1);
    return if (axis == .horizontal) child.width else child.height;
}

fn distribute(
    comptime Slot: type,
    children: []const View(Slot),
    box: Rect,
    axis: Axis,
    gap: u16,
    comptime sizes: enum { own, equal },
    visitor: anytype,
) void {
    if (children.len == 0) return;
    const extent = box.along(axis).width;
    var fixed: u32 = 0;
    var weights: u32 = 0;
    for (children) |*child| {
        const size = if (sizes == .equal) Size.fill(1) else mainSize(Slot, child, axis);
        switch (size.basis) {
            .fill => |weight| weights += weight,
            else => fixed += size.want(extent),
        }
    }
    const gaps: u32 = @as(u32, gap) * @as(u32, @intCast(children.len - 1));
    var fill_left: u32 = @as(u32, extent) -| fixed -| gaps;
    var weight_left = weights;
    var cursor: u32 = 0;
    for (children, 0..) |*child, index| {
        const size = if (sizes == .equal) Size.fill(1) else mainSize(Slot, child, axis);
        const wanted: u32 = switch (size.basis) {
            .fill => |weight| blk: {
                const share = if (weight >= weight_left) fill_left else fill_left * weight / weight_left;
                fill_left -= share;
                weight_left -|= weight;
                break :blk size.clamp(share);
            },
            else => size.want(extent),
        };
        const len = @min(wanted, @as(u32, extent) -| cursor);
        walk(Slot, child, box.slice(axis, cursor, len), visitor);
        cursor +|= len;
        if (index + 1 < children.len) cursor +|= gap;
    }
}

fn itemWidth(comptime Slot: type, child: *const View(Slot), extent: u16) u16 {
    return if (child.width.isFill()) 1 else child.width.want(extent);
}

fn itemHeight(comptime Slot: type, child: *const View(Slot), extent: u16) u16 {
    return if (child.height.isFill()) 1 else child.height.want(extent);
}

fn wrapRows(
    comptime Slot: type,
    children: []const View(Slot),
    box: Rect,
    gap: u16,
    row_gap: u16,
    justify: Align,
    visitor: anytype,
) void {
    var y: u32 = 0;
    var first: usize = 0;
    while (first < children.len) {
        var used: u32 = itemWidth(Slot, &children[first], box.width);
        var row_height: u16 = itemHeight(Slot, &children[first], box.height);
        var end = first + 1;
        while (end < children.len) : (end += 1) {
            const next = used + gap + itemWidth(Slot, &children[end], box.width);
            if (next > box.width) break;
            used = next;
            row_height = @max(row_height, itemHeight(Slot, &children[end], box.height));
        }
        const free: u32 = @as(u32, box.width) -| used;
        var x: u32 = switch (justify) {
            .start => 0,
            .center => free / 2,
            .end => free,
        };
        const row = box.slice(.vertical, y, row_height);
        for (children[first..end]) |*child| {
            const width = itemWidth(Slot, child, box.width);
            const cell = row.slice(.horizontal, x, width);
            walk(Slot, child, cell.slice(.vertical, 0, itemHeight(Slot, child, box.height)), visitor);
            x +|= width +| gap;
        }
        y +|= @as(u32, row_height) +| row_gap;
        first = end;
    }
}

fn placeRepel(comptime Slot: type, children: []const View(Slot), box: Rect, gap: u16, wrap: bool, visitor: anytype) void {
    var wanted: u32 = 0;
    for (children) |*child| wanted += itemWidth(Slot, child, box.width);
    const gaps: u32 = @as(u32, gap) * @as(u32, @intCast(children.len -| 1));
    const overflow = (wanted + gaps) -| box.width;
    if (overflow > 0 and wrap) return wrapRows(Slot, children, box, gap, 0, .start, visitor);
    const free: u32 = @as(u32, box.width) -| (wanted + gaps);
    const spaces: u32 = @intCast(@max(1, children.len -| 1));
    var after = wanted;
    var x: u32 = 0;
    for (children, 0..) |*child, index| {
        const want = itemWidth(Slot, child, box.width);
        after -= want;
        const shrink = @min(want, overflow -| after);
        const width = want - shrink;
        walk(Slot, child, box.slice(.horizontal, x, width).slice(.vertical, 0, itemHeight(Slot, child, box.height)), visitor);
        const extra = if (children.len < 2) 0 else free / spaces + @intFromBool(index < free % spaces);
        x += width + gap + extra;
    }
}

fn placeSidebar(
    comptime Slot: type,
    children: []const View(Slot),
    box: Rect,
    sidebar: @FieldType(Composition, "sidebar"),
    visitor: anytype,
) void {
    std.debug.assert(children.len == 2);
    const side_index: usize = if (sidebar.side == .start) 0 else 1;
    const side = &children[side_index];
    const main = &children[1 - side_index];
    const wanted = side.width.want(box.width);
    if (sidebar.wrap and @as(u32, wanted) + sidebar.gap + sidebar.content_min > box.width)
        return distribute(Slot, children, box, .vertical, sidebar.gap, .own, visitor);
    const side_width: u32 = @min(wanted, @as(u32, box.width) -| sidebar.gap -| sidebar.content_min);
    const main_width: u32 = @as(u32, box.width) -| side_width -| sidebar.gap;
    if (sidebar.side == .start) {
        walk(Slot, side, box.slice(.horizontal, 0, side_width), visitor);
        walk(Slot, main, box.slice(.horizontal, side_width + sidebar.gap, main_width), visitor);
    } else {
        walk(Slot, main, box.slice(.horizontal, 0, main_width), visitor);
        walk(Slot, side, box.slice(.horizontal, main_width + sidebar.gap, side_width), visitor);
    }
}

fn placeGrid(comptime Slot: type, children: []const View(Slot), box: Rect, min_item: u16, gap: u16, row_gap: u16, visitor: anytype) void {
    if (children.len == 0) return;
    const columns: u32 = @max(1, (@as(u32, box.width) + gap) / (@as(u32, min_item) + gap));
    const inner: u32 = @as(u32, box.width) -| gap * (columns - 1);
    var y: u32 = 0;
    var first: usize = 0;
    while (first < children.len) {
        const end = @min(children.len, first + columns);
        var row_height: u16 = 0;
        for (children[first..end]) |*child| row_height = @max(row_height, itemHeight(Slot, child, box.height));
        const row = box.slice(.vertical, y, row_height);
        var x: u32 = 0;
        for (children[first..end], 0..) |*child, column| {
            const width = inner / columns + @intFromBool(column < inner % columns);
            walk(Slot, child, row.slice(.horizontal, x, width), visitor);
            x += width + gap;
        }
        y +|= @as(u32, row_height) +| row_gap;
        first = end;
    }
}

fn placeReel(comptime Slot: type, children: []const View(Slot), box: Rect, offset: u32, gap: u16, visitor: anytype) void {
    var start: u32 = 0;
    for (children) |*child| {
        const width: u32 = if (child.width.isFill()) box.width else child.width.want(box.width);
        const end = start +| width;
        const visible_start = @max(start, offset);
        const visible_end = @min(end, offset +| box.width);
        const rect = if (visible_end > visible_start)
            box.slice(.horizontal, visible_start - offset, visible_end - visible_start)
        else
            box.slice(.horizontal, box.width, 0);
        walk(Slot, child, rect, visitor);
        start = end +| gap;
    }
}

pub fn Rects(comptime Slot: type) type {
    return std.EnumArray(Slot, Placed);
}

/// A visitor that keeps the rects of each Slot. Every Slot must be placed
/// exactly once.
pub fn Solver(comptime Slot: type) type {
    return struct {
        const Self = @This();

        rects: Rects(Slot) = .initFill(.{}),
        placed: std.EnumSet(Slot) = .initEmpty(),

        pub fn visit(self: *Self, node: *const View(Slot), placed: Placed) void {
            const slot = node.slot orelse return;
            std.debug.assert(!self.placed.contains(slot));
            self.placed.insert(slot);
            self.rects.set(slot, placed);
        }

        pub fn finish(self: Self) Rects(Slot) {
            std.debug.assert(self.placed.count() == std.enums.values(Slot).len);
            return self.rects;
        }
    };
}

/// Solve one layout function `tree(params, area, visitor)` into the rects of
/// its Slots.
pub fn solve(comptime Slot: type, comptime tree: anytype, params: anytype, area: Rect) Rects(Slot) {
    var solver: Solver(Slot) = .{};
    tree(params, area, &solver);
    return solver.finish();
}

const testing = std.testing;

const TestSlot = enum { a, b, c };
const TestView = View(TestSlot);

fn solveRoot(root: TestView, area: Rect) Rects(TestSlot) {
    var solver: Solver(TestSlot) = .{};
    walk(TestSlot, &root, area, &solver);
    return solver.rects;
}

test "the box model nests margin, border, padding, and content" {
    const rects = solveRoot(.{
        .slot = .a,
        .margin = .{ .top = 1, .left = 2 },
        .border = .{},
        .padding = Edges.sides(1),
    }, .{ .width = 20, .height = 10 });
    const a = rects.get(.a);
    try testing.expectEqual(Rect{ .x = 2, .y = 1, .width = 18, .height = 9 }, a.border);
    try testing.expectEqual(Rect{ .x = 3, .y = 2, .width = 16, .height = 7 }, a.padding);
    try testing.expectEqual(Rect{ .x = 4, .y = 2, .width = 14, .height = 7 }, a.content);
}

test "a scroll bar takes the trailing cell of its ring and keeps the content rect" {
    const area: Rect = .{ .width = 10, .height = 6 };
    const bar: Scrollbar = .{ .ring = .border, .total = 40 };
    const in_border = (TestView{ .border = .{}, .scrollbar = bar }).place(area);
    try testing.expectEqual((TestView{ .border = .{} }).place(area).content, in_border.content);
    try testing.expectEqual(Rect{ .x = 9, .y = 1, .width = 1, .height = 4 }, in_border.track);

    var padded = bar;
    padded.ring = .padding;
    const in_padding = (TestView{ .border = .{}, .scrollbar = padded }).place(area);
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 7, .height = 4 }, in_padding.content);
    try testing.expectEqual(Rect{ .x = 8, .y = 1, .width = 1, .height = 4 }, in_padding.track);

    var outside = bar;
    outside.ring = .margin;
    outside.axis = .horizontal;
    const in_margin = (TestView{ .border = .{}, .scrollbar = outside }).place(area);
    try testing.expectEqual(Rect{ .x = 0, .y = 5, .width = 10, .height = 1 }, in_margin.track);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 10, .height = 5 }, in_margin.border);
}

test "a flow gives fixed children their cells and shares the rest by weight" {
    const rects = solveRoot(.{
        .composition = .{ .flow = .{ .gap = 1 } },
        .children = &.{
            .{ .slot = .a, .height = .cells(2) },
            .{ .slot = .b, .height = .fill(1) },
            .{ .slot = .c, .height = .fill(2) },
        },
    }, .{ .width = 4, .height = 12 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 2 }, rects.get(.a).margin);
    try testing.expectEqual(Rect{ .x = 0, .y = 3, .width = 4, .height = 2 }, rects.get(.b).margin);
    try testing.expectEqual(Rect{ .x = 0, .y = 6, .width = 4, .height = 6 }, rects.get(.c).margin);
}

test "a flow never places a child outside its content box" {
    const rects = solveRoot(.{
        .composition = .{ .flow = .{ .axis = .horizontal } },
        .children = &.{ .{ .slot = .a, .width = .cells(5) }, .{ .slot = .b, .composition = .{ .rule = .{} } }, .{ .slot = .c } },
    }, .{ .x = 3, .width = 5, .height = 1 });
    try testing.expectEqual(@as(u16, 5), rects.get(.a).margin.width);
    try testing.expect(rects.get(.b).margin.isEmpty());
    try testing.expect(rects.get(.c).margin.isEmpty());
    try testing.expect(rects.get(.c).margin.x <= 8);
}

test "a sidebar keeps its target width until the main child reaches its minimum" {
    var root: TestView = .{
        .composition = .{ .sidebar = .{ .content_min = 10, .gap = 1, .wrap = false } },
        .children = &.{ .{ .slot = .b, .width = .cells(8), .height = .cells(1) }, .{ .slot = .c } },
    };
    var rects = solveRoot(root, .{ .width = 30, .height = 3 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 8, .height = 3 }, rects.get(.b).margin);
    try testing.expectEqual(Rect{ .x = 9, .y = 0, .width = 21, .height = 3 }, rects.get(.c).margin);
    rects = solveRoot(root, .{ .width = 15, .height = 3 });
    try testing.expectEqual(@as(u16, 4), rects.get(.b).margin.width);
    try testing.expectEqual(@as(u16, 10), rects.get(.c).margin.width);

    root.composition.sidebar.wrap = true;
    rects = solveRoot(root, .{ .width = 15, .height = 4 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 15, .height = 1 }, rects.get(.b).margin);
    try testing.expectEqual(Rect{ .x = 0, .y = 2, .width = 15, .height = 2 }, rects.get(.c).margin);
}

test "a cluster wraps and justifies its rows" {
    const rects = solveRoot(.{
        .composition = .{ .cluster = .{ .gap = 1, .justify = .end } },
        .children = &.{ .{ .slot = .a, .width = .cells(4) }, .{ .slot = .b, .width = .cells(4) }, .{ .slot = .c, .width = .cells(3) } },
    }, .{ .width = 10, .height = 4 });
    try testing.expectEqual(Rect{ .x = 1, .y = 0, .width = 4, .height = 1 }, rects.get(.a).margin);
    try testing.expectEqual(Rect{ .x = 6, .y = 0, .width = 4, .height = 1 }, rects.get(.b).margin);
    try testing.expectEqual(Rect{ .x = 7, .y = 1, .width = 3, .height = 1 }, rects.get(.c).margin);
}

test "a repel pushes the first and last children to the ends" {
    const rects = solveRoot(.{
        .composition = .{ .repel = .{} },
        .children = &.{ .{ .slot = .a, .width = .cells(3) }, .{ .slot = .b, .width = .cells(2) }, .{ .slot = .c, .width = .cells(2) } },
    }, .{ .width = 12, .height = 1 });
    try testing.expectEqual(@as(u16, 0), rects.get(.a).margin.x);
    try testing.expectEqual(@as(u16, 10), rects.get(.c).margin.x);
    try testing.expectEqual(@as(u16, 6), rects.get(.b).margin.x);
}

test "a repel without wrap shrinks its last children to fit one row" {
    const rects = solveRoot(.{
        .composition = .{ .repel = .{ .gap = 2, .wrap = false } },
        .children = &.{ .{ .slot = .a, .width = .cells(6) }, .{ .slot = .b, .width = .cells(4) }, .{ .slot = .c, .width = .cells(5) } },
    }, .{ .width = 14, .height = 1 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 6, .height = 1 }, rects.get(.a).margin);
    try testing.expectEqual(Rect{ .x = 8, .y = 0, .width = 4, .height = 1 }, rects.get(.b).margin);
    try testing.expect(rects.get(.c).margin.isEmpty());
}

test "a switcher stacks below its threshold" {
    const root: TestView = .{
        .composition = .{ .switcher = .{ .threshold = 20 } },
        .children = &.{ .{ .slot = .a, .height = .cells(2) }, .{ .slot = .b } },
    };
    var solver: Solver(TestSlot) = .{};
    walk(TestSlot, &root, .{ .width = 20, .height = 6 }, &solver);
    try testing.expectEqual(Rect{ .x = 10, .y = 0, .width = 10, .height = 6 }, solver.rects.get(.b).margin);
    solver = .{};
    walk(TestSlot, &root, .{ .width = 19, .height = 6 }, &solver);
    try testing.expectEqual(Rect{ .x = 0, .y = 2, .width = 19, .height = 4 }, solver.rects.get(.b).margin);
}

test "a grid fits columns of its minimum width" {
    const rects = solveRoot(.{
        .composition = .{ .grid = .{ .min_item = 4, .gap = 1 } },
        .children = &.{ .{ .slot = .a }, .{ .slot = .b }, .{ .slot = .c } },
    }, .{ .width = 10, .height = 4 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 5, .height = 1 }, rects.get(.a).margin);
    try testing.expectEqual(Rect{ .x = 6, .y = 0, .width = 4, .height = 1 }, rects.get(.b).margin);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .width = 5, .height = 1 }, rects.get(.c).margin);
}

test "a reel scrolls its children and empties the ones out of view" {
    const rects = solveRoot(.{
        .composition = .{ .reel = .{ .offset = 5, .gap = 1 } },
        .children = &.{ .{ .slot = .a, .width = .cells(4) }, .{ .slot = .b, .width = .cells(4) }, .{ .slot = .c, .width = .cells(4) } },
    }, .{ .width = 6, .height = 2 });
    try testing.expect(rects.get(.a).margin.isEmpty());
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 2 }, rects.get(.b).margin);
    try testing.expectEqual(Rect{ .x = 5, .y = 0, .width = 1, .height = 2 }, rects.get(.c).margin);
}

test "center clips its child and centers it" {
    const rects = solveRoot(.{
        .composition = .{ .center = .{} },
        .children = &.{.{ .slot = .a, .width = .{ .basis = .{ .fraction = .{ .num = 4, .den = 5 } }, .min = 64 }, .height = .cells(16) }},
    }, .{ .width = 80, .height = 24 });
    try testing.expectEqual(Rect{ .x = 8, .y = 4, .width = 64, .height = 16 }, rects.get(.a).margin);
}

test "the scroll bar thumb covers the visible share of the content" {
    try testing.expect(thumb(10, 10, 0) == null);
    try testing.expectEqual(Thumb{ .first = 0, .len = 5 }, thumb(10, 20, 0).?);
    try testing.expectEqual(Thumb{ .first = 5, .len = 5 }, thumb(10, 20, 10).?);
    try testing.expectEqual(Thumb{ .first = 9, .len = 1 }, thumb(10, 1000, 990).?);
}
