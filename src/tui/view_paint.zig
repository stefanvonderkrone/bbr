//! The one painter of View decoration: fills, borders, rounded corners,
//! rules, junctions, Titles, and scroll bars. Content painters draw only into
//! a content rect that this painter returns. See ADR-0013.

const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("view.zig");
const Theme = @import("theme.zig").Theme;

/// Walk the layout `tree` over all of `win`, paint the decoration of every
/// View in tree order, and return the rects of its Slots.
pub fn paint(comptime Slot: type, comptime tree: anytype, params: anytype, win: vaxis.Window, theme: Theme) view.Rects(Slot) {
    var painter: Painter(Slot) = .{ .win = win, .theme = theme };
    tree(params, .{ .width = win.width, .height = win.height }, &painter);
    return painter.solver.finish();
}

fn Painter(comptime Slot: type) type {
    return struct {
        const Self = @This();

        win: vaxis.Window,
        theme: Theme,
        solver: view.Solver(Slot) = .{},

        pub fn visit(self: *Self, node: *const view.View(Slot), placed: view.Placed) void {
            self.solver.visit(node, placed);
            if (node.fill) fillRect(self.win, placed.border, self.theme.picker);
            if (node.border) |border| drawBorder(self.win, placed.border, strokeStyle(self.theme, border.stroke));
            if (node.composition == .rule) drawRule(self.win, placed.border, strokeStyle(self.theme, node.composition.rule));
            if (node.title) |title| drawTitle(self.win, node, placed, title);
            if (node.scrollbar) |bar| drawScrollbar(self.win, placed.track, bar, strokeStyle(self.theme, bar.stroke));
        }
    };
}

pub fn strokeStyle(theme: Theme, stroke: view.Stroke) vaxis.Style {
    return switch (stroke.tone) {
        .pane => if (stroke.focused) theme.pane_border_focused else theme.pane_border,
        .overlay => theme.overlay_border,
    };
}

fn fillRect(win: vaxis.Window, rect: view.Rect, style: vaxis.Style) void {
    for (rect.y..rect.y +| rect.height) |row| for (rect.x..rect.x +| rect.width) |col|
        win.writeCell(@intCast(col), @intCast(row), .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
}

fn writeGlyph(win: vaxis.Window, col: usize, row: usize, grapheme: []const u8, style: vaxis.Style) void {
    win.writeCell(@intCast(col), @intCast(row), .{ .char = .{ .grapheme = grapheme, .width = 1 }, .style = style });
}

fn drawBorder(win: vaxis.Window, rect: view.Rect, style: vaxis.Style) void {
    if (rect.isEmpty()) return;
    const corners = [4][]const u8{ "╭", "╮", "╰", "╯" };
    const left: usize = rect.x;
    const right: usize = rect.x + rect.width - 1;
    const top: usize = rect.y;
    const bottom: usize = rect.y + rect.height - 1;
    for (left..right + 1) |col| {
        writeGlyph(win, col, top, if (col == left) corners[0] else if (col == right) corners[1] else "─", style);
        if (bottom > top) writeGlyph(win, col, bottom, if (col == left) corners[2] else if (col == right) corners[3] else "─", style);
    }
    if (bottom > top + 1) for (top + 1..bottom) |row| {
        writeGlyph(win, left, row, "│", style);
        if (right > left) writeGlyph(win, right, row, "│", style);
    };
}

/// A rule runs along the long side of its rect and joins the lines at both ends.
fn drawRule(win: vaxis.Window, rect: view.Rect, style: vaxis.Style) void {
    if (rect.isEmpty()) return;
    if (rect.width >= rect.height) {
        for (rect.x..rect.x + rect.width) |col| writeGlyph(win, col, rect.y, "─", style);
        if (rect.x > 0) join(win, rect.x - 1, rect.y, .{ .right = true });
        join(win, rect.x +| rect.width, rect.y, .{ .left = true });
    } else {
        for (rect.y..rect.y + rect.height) |row| writeGlyph(win, rect.x, row, "│", style);
        if (rect.y > 0) join(win, rect.x, rect.y - 1, .{ .down = true });
        join(win, rect.x, rect.y +| rect.height, .{ .up = true });
    }
}

fn drawTitle(win: vaxis.Window, node: anytype, placed: view.Placed, title: view.Title) void {
    if (title.text.len == 0) return;
    const line: struct { row: u32, start: u32, width: u32 } = if (node.border != null) .{
        .row = if (title.edge == .top) placed.border.y else @as(u32, placed.border.y) + placed.border.height -| 1,
        .start = placed.border.x,
        .width = placed.border.width,
    } else if (node.composition == .rule) .{
        .row = placed.border.y,
        .start = placed.border.x -| 1,
        .width = @as(u32, placed.border.width) + @min(placed.border.x, 1) + 1,
    } else .{
        .row = if (title.edge == .top) @as(u32, placed.margin.y) -% 1 else @as(u32, placed.margin.y) + placed.margin.height,
        .start = placed.margin.x -| 1,
        .width = @as(u32, placed.margin.width) + @min(placed.margin.x, 1) + 1,
    };
    if (line.row >= win.height or line.width == 0) return;
    const end = @min(line.start + line.width, win.width);
    const text_width: u32 = @as(u32, @intCast(vaxis.gwidth.gwidth(title.text, .unicode))) + 2;
    const margin = 2 * @as(u32, title.inset);
    const col: u32 = switch (title.@"align") {
        .start => line.start + title.inset,
        .end => (line.start + line.width) -| title.inset -| text_width,
        .center => if (line.width > text_width + margin) line.start + (line.width - text_width) / 2 else return,
    };
    const limit = @min(end, line.start + line.width -| title.inset);
    if (col >= limit) return;
    const style = if (win.readCell(@intCast(col), @intCast(line.row))) |cell| cell.style else vaxis.Style{};
    titleText(win, .{ .x = @intCast(col), .y = @intCast(line.row), .width = @intCast(limit - col), .height = 1 }, title.text, style);
}

/// Paint a Title into a border row with one blank cell on each side, so the
/// text never touches the line. Text that does not fit is cut inside the
/// blank cells, which stay within `rect`.
pub fn titleText(win: vaxis.Window, rect: view.Rect, text: []const u8, style: vaxis.Style) void {
    if (rect.width < 3 or rect.height == 0) return;
    const width: u16 = @intCast(@min(vaxis.gwidth.gwidth(text, .unicode), rect.width - 2));
    const span: view.Rect = .{ .x = rect.x + 1, .y = rect.y, .width = width, .height = 1 };
    _ = win.child(.{ .x_off = span.x, .y_off = span.y, .width = span.width, .height = 1 }).printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
    titleGaps(win, span, style);
}

/// Blank the cell before and after a Title span that its owner painted, such
/// as the DiffPane's Selected Version control.
pub fn titleGaps(win: vaxis.Window, span: view.Rect, style: vaxis.Style) void {
    if (span.x > 0) writeGlyph(win, span.x - 1, span.y, " ", style);
    writeGlyph(win, span.x +| span.width, span.y, " ", style);
}

/// One row of a ReviewCard border. A ReviewCard is a run of Buffer rows, not
/// one View, so its painter asks for its border one row at a time.
pub const CardEdge = union(enum) {
    /// The top border with the Title after `╭─`.
    top: []const u8,
    /// The left and right borders of a content row.
    side,
    /// The bottom border, with an optional Title before `─╯`.
    bottom: []const u8,
};

/// Paint the `edge` of a ReviewCard whose borders sit in columns `left` and
/// `right` of `row`. The Title gets one blank cell on each side.
pub fn cardEdge(win: vaxis.Window, row: u16, left: usize, right: usize, edge: CardEdge, border: vaxis.Style, title: vaxis.Style) void {
    if (right <= left) return;
    switch (edge) {
        .side => {
            writeGlyph(win, left, row, "│", border);
            writeGlyph(win, right, row, "│", border);
        },
        .top => |text| {
            cardRule(win, row, left, right, "╭", "╮", border);
            if (text.len > 0) titleText(win, .{ .x = @intCast(left + 2), .y = row, .width = @intCast((right - left) -| 3), .height = 1 }, text, title);
        },
        .bottom => |text| {
            cardRule(win, row, left, right, "╰", "╯", border);
            if (text.len == 0) return;
            const x = @max(left + 2, (right - 1) -| (vaxis.gwidth.gwidth(text, .unicode) + 2));
            titleText(win, .{ .x = @intCast(x), .y = row, .width = @intCast((right - 1) -| x), .height = 1 }, text, title);
        },
    }
}

fn cardRule(win: vaxis.Window, row: u16, left: usize, right: usize, start: []const u8, end: []const u8, style: vaxis.Style) void {
    for (left..right + 1) |col| writeGlyph(win, col, row, if (col == left) start else if (col == right) end else "─", style);
}

/// The line that runs past one row down to a later sibling card. It paints
/// `│` only in a blank cell, so it never covers a border or text.
pub fn rail(win: vaxis.Window, col: usize, row: u16, style: vaxis.Style) void {
    if (col >= win.width or row >= win.height) return;
    const cell = win.readCell(@intCast(col), row) orelse return;
    if (!std.mem.eql(u8, cell.char.grapheme, " ")) return;
    writeGlyph(win, col, row, "│", style);
}

/// The piece of an Anchor Indicator in column 0 of a row above the root card:
/// `╭` on the top anchored Diff Line and `│` on every row below it.
pub fn anchorIndicator(win: vaxis.Window, row: u16, top: bool, style: vaxis.Style) void {
    writeGlyph(win, 0, row, if (top) "╭" else "│", style);
}

/// The end of an Anchor Indicator on the root card's top border row: `╰` in
/// column 0, which joins the card's top-left corner in column 1.
pub fn anchorCorner(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    writeGlyph(win, 0, row, "╰", style);
    join(win, 1, row, .{ .left = true });
}

fn drawScrollbar(win: vaxis.Window, track: view.Rect, bar: view.Scrollbar, style: vaxis.Style) void {
    const extent = if (bar.axis == .vertical) track.height else track.width;
    const range = view.thumb(extent, bar.total, bar.offset) orelse return;
    const grapheme: []const u8 = switch (bar.axis) {
        .vertical => if (bar.ring == .border) "┃" else "│",
        .horizontal => if (bar.ring == .border) "━" else "─",
    };
    for (range.first..range.first + range.len) |step| switch (bar.axis) {
        .vertical => writeGlyph(win, track.x, track.y + step, grapheme, style),
        .horizontal => writeGlyph(win, track.x + step, track.y, grapheme, style),
    };
}

/// The line arms that leave one cell.
pub const Arms = packed struct(u4) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    fn bits(self: Arms) u4 {
        return @bitCast(self);
    }
};

const lines = [_]struct { []const u8, Arms }{
    .{ "─", .{ .left = true, .right = true } },
    .{ "│", .{ .up = true, .down = true } },
    .{ "┌", .{ .down = true, .right = true } },
    .{ "┐", .{ .down = true, .left = true } },
    .{ "└", .{ .up = true, .right = true } },
    .{ "┘", .{ .up = true, .left = true } },
    .{ "├", .{ .up = true, .down = true, .right = true } },
    .{ "┤", .{ .up = true, .down = true, .left = true } },
    .{ "┬", .{ .down = true, .left = true, .right = true } },
    .{ "┴", .{ .up = true, .left = true, .right = true } },
    .{ "┼", .{ .up = true, .down = true, .left = true, .right = true } },
    .{ "╭", .{ .down = true, .right = true } },
    .{ "╮", .{ .down = true, .left = true } },
    .{ "╰", .{ .up = true, .right = true } },
    .{ "╯", .{ .up = true, .left = true } },
};

fn armsOf(grapheme: []const u8) ?Arms {
    for (lines) |entry| if (std.mem.eql(u8, entry[0], grapheme)) return entry[1];
    return null;
}

fn glyphOf(arms: Arms) []const u8 {
    for (lines) |entry| if (entry[1].bits() == arms.bits()) return entry[0];
    return if (arms.left or arms.right) "─" else "│";
}

/// Add `arms` to the line glyph at one cell. A changed cell takes `style`, or
/// keeps its own when `style` is null. A cell that holds no line glyph, such
/// as a scroll bar thumb or text, does not change.
pub fn join(win: vaxis.Window, col: usize, row: usize, arms: Arms) void {
    if (col >= win.width or row >= win.height) return;
    const cell = win.readCell(@intCast(col), @intCast(row)) orelse return;
    const have = armsOf(cell.char.grapheme) orelse return;
    const merged: Arms = @bitCast(have.bits() | arms.bits());
    if (merged.bits() == have.bits()) return;
    writeGlyph(win, col, row, glyphOf(merged), cell.style);
}

const testing = std.testing;

fn headless(screen: *vaxis.Screen) vaxis.Window {
    return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = screen };
}

fn rowText(win: vaxis.Window, row: u16, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (0..win.width) |col| {
        const grapheme = win.readCell(@intCast(col), row).?.char.grapheme;
        @memcpy(buffer[len..][0..grapheme.len], grapheme);
        len += grapheme.len;
    }
    return buffer[0..len];
}

const Pair = enum { left, right };

fn splitTree(_: void, area: view.Rect, visitor: anytype) void {
    const stroke: view.Stroke = .{ .tone = .overlay };
    const root: view.View(Pair) = .{
        .border = .{ .stroke = stroke },
        .composition = .{ .flow = .{ .axis = .horizontal } },
        .children = &.{
            .{ .slot = .left, .width = .cells(3), .title = .{ .text = "A", .@"align" = .center, .inset = 0 } },
            .{ .composition = .{ .rule = stroke } },
            .{ .slot = .right, .scrollbar = .{ .ring = .padding, .total = 6, .offset = 0 } },
        },
    };
    view.walk(Pair, &root, area, visitor);
}

test "the painter joins a rule into its parent border and paints Titles and thumbs" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 4, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = headless(&screen);
    const rects = paint(Pair, splitTree, {}, win, @import("theme.zig").dark);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("╭ A ┬────╮", rowText(win, 0, &buffer));
    try testing.expectEqualStrings("│   │   ││", rowText(win, 1, &buffer));
    try testing.expectEqualStrings("│   │    │", rowText(win, 2, &buffer));
    try testing.expectEqualStrings("╰───┴────╯", rowText(win, 3, &buffer));
    try testing.expectEqual(view.Rect{ .x = 5, .y = 1, .width = 3, .height = 2 }, rects.get(.right).content);
}

test "a join leaves text and thumbs alone" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = headless(&screen);
    writeGlyph(win, 0, 0, "│", .{});
    writeGlyph(win, 1, 0, "┃", .{});
    writeGlyph(win, 2, 0, "a", .{});
    join(win, 0, 0, .{ .right = true });
    join(win, 1, 0, .{ .right = true });
    join(win, 2, 0, .{ .right = true });
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("├┃a", rowText(win, 0, &buffer));
}
