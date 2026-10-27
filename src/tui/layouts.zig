//! The View tree of each terminal surface. Each tree is a function
//! `fn (params, area, visitor) void` that builds its Views on its own stack
//! and walks them. `view.solve` turns a tree into the rects of its Slots, and
//! view_paint.zig paints the same walk. See ADR-0013.

const std = @import("std");
const view = @import("view.zig");

const Rect = view.Rect;
const Size = view.Size;

/// The numbers of a scroll bar. A tree always declares its scroll bars, so
/// the rects do not depend on these numbers, and a solve without them
/// matches the paint.
pub const Scroll = struct { total: usize = 0, offset: usize = 0 };

fn bar(scroll: Scroll, ring: view.Ring, stroke: view.Stroke) view.Scrollbar {
    return .{ .ring = ring, .total = scroll.total, .offset = scroll.offset, .stroke = stroke };
}

/// The terminal window: the content area above the status rows, as many as
/// `statusHeight` returns.
pub const AppSlot = enum { content, status };

pub fn app(status_rows: u16, area: Rect, visitor: anytype) void {
    const root: view.View(AppSlot) = .{
        .composition = .{ .flow = .{} },
        .children = &.{ .{ .slot = .content }, .{ .slot = .status, .height = .cells(status_rows) } },
    };
    view.walk(AppSlot, &root, area, visitor);
}

/// The status: the meta part above the hint part. Each part is a cluster of
/// one-row items that wraps by item and never inside one. The meta part is
/// the Slots before `layout`, the hint part the rest.
pub const StatusSlot = enum {
    search,
    title,
    verdict,
    refs,
    position,
    layout,
    scope,
    isolate,
    message,
    submit,
    comment,
    file,
    switch_review,
    help,
    quit,

    fn inMeta(self: StatusSlot) bool {
        return @intFromEnum(self) < @intFromEnum(StatusSlot.layout);
    }
};

/// The cell width of each status item. An item of width 0 is absent: the
/// tree leaves it out, and its rects stay empty.
pub const Status = std.EnumArray(StatusSlot, u16);

pub const status_padding: u16 = 1;
/// The cells between two items on one row, where app.zig paints `  ·  `.
pub const status_gap: u16 = 5;

pub fn status(params: Status, area: Rect, visitor: anytype) void {
    const V = view.View(StatusSlot);
    var meta: [std.enums.values(StatusSlot).len]V = undefined;
    var hints: [meta.len]V = undefined;
    var meta_len: usize = 0;
    var hints_len: usize = 0;
    for (std.enums.values(StatusSlot)) |slot| {
        const width = params.get(slot);
        if (width == 0) continue;
        const item: V = .{ .slot = slot, .width = .cells(width), .height = .cells(1) };
        if (slot.inMeta()) {
            meta[meta_len] = item;
            meta_len += 1;
        } else {
            hints[hints_len] = item;
            hints_len += 1;
        }
    }
    const padding = view.Edges.sides(status_padding);
    const width = area.inset(padding).width;
    const parts = [_]V{ statusPart(meta[0..meta_len], width), statusPart(hints[0..hints_len], width) };
    const root: V = .{ .padding = padding, .composition = .{ .flow = .{} }, .children = &parts };
    view.walk(StatusSlot, &root, area, visitor);
}

/// A cluster of `items`, as tall as its rows at `width`.
fn statusPart(items: []const view.View(StatusSlot), width: u16) view.View(StatusSlot) {
    var part: view.View(StatusSlot) = .{ .composition = .{ .cluster = .{ .gap = status_gap } }, .children = items };
    var bottom: ItemsBottom = .{};
    view.walk(StatusSlot, &part, .{ .width = width, .height = std.math.maxInt(u16) }, &bottom);
    part.height = .cells(bottom.row);
    return part;
}

/// The rows the status needs at `width`: the bottom of its lowest item when
/// the status tree lays out from row 0.
pub fn statusHeight(params: Status, width: u16) u16 {
    var bottom: ItemsBottom = .{};
    status(params, .{ .width = width, .height = std.math.maxInt(u16) }, &bottom);
    return bottom.row;
}

const ItemsBottom = struct {
    row: u16 = 0,

    pub fn visit(self: *ItemsBottom, node: *const view.View(StatusSlot), placed: view.Placed) void {
        if (node.slot != null) self.row = @max(self.row, placed.margin.y +| placed.margin.height);
    }
};

/// The rects of each status item in `area`. An absent item keeps empty rects.
pub fn statusRects(params: Status, area: Rect) view.Rects(StatusSlot) {
    var solver: view.Solver(StatusSlot) = .{};
    status(params, area, &solver);
    return solver.rects;
}

/// The Sidebar and the DiffPane. Each Pane has a rounded border with its
/// Title in the top border, and its body starts in the next row. The scroll
/// bars sit in the right border.
pub const PaneSlot = enum { sidebar, diff };

pub const Panes = struct {
    sidebar_focused: bool = false,
    sidebar_scroll: Scroll = .{},
    diff_scroll: Scroll = .{},
};

pub const sidebar_width: u16 = 28;

pub fn panes(params: Panes, area: Rect, visitor: anytype) void {
    const V = view.View(PaneSlot);
    const sidebar_stroke: view.Stroke = .{ .focused = params.sidebar_focused };
    const diff_stroke: view.Stroke = .{ .focused = !params.sidebar_focused };
    const root: V = .{
        .composition = .{ .sidebar = .{ .content_min = 3, .wrap = false } },
        .children = &.{
            .{
                .slot = .sidebar,
                .width = .cells(sidebar_width),
                .border = .{ .stroke = sidebar_stroke },
                .title = .{ .text = "Files" },
                .scrollbar = bar(params.sidebar_scroll, .border, sidebar_stroke),
            },
            .{
                .slot = .diff,
                .border = .{ .stroke = diff_stroke },
                .scrollbar = bar(params.diff_scroll, .border, diff_stroke),
            },
        },
    };
    view.walk(PaneSlot, &root, area, visitor);
}

pub const Box = struct { width: u16, height: u16 };

const overlay_stroke: view.Stroke = .{ .tone = .overlay };

/// The surface of an Overlay without a text input: a filled box with a
/// rounded border around `box` content cells. An Overlay with a text input
/// uses `inputSurface`.
fn overlaySurface(comptime Slot: type, box: Box, node: view.View(Slot)) view.View(Slot) {
    var result = node;
    result.width = .cells(box.width +| 2);
    result.height = .cells(box.height +| 2);
    result.fill = true;
    result.border = .{ .stroke = overlay_stroke };
    return result;
}

/// The surface of an Overlay with a text input. It is a filled flow of the
/// input box, one row inside a rounded border, above the result box, which
/// takes the rest inside its own rounded border. The surface has no border.
/// An Overlay without a text input uses `overlaySurface`.
fn inputSurface(comptime Slot: type, slot: Slot, width: Size, height: Size, boxes: *[2]view.View(Slot)) view.View(Slot) {
    boxes[0].height = .cells(3);
    for (boxes) |*box| box.border = .{ .stroke = overlay_stroke };
    return .{ .slot = slot, .width = width, .height = height, .fill = true, .composition = .{ .flow = .{} }, .children = boxes };
}

/// A List Overlay: the query box, with the Overlay's Title, above the box of
/// ranked entries. `box` counts one query row plus the entry rows.
pub const ListSlot = enum { surface, query, entries };

pub const ListOverlay = struct {
    box: Box,
    title: []const u8 = "",
};

pub fn listOverlay(params: ListOverlay, area: Rect, visitor: anytype) void {
    var boxes = [_]view.View(ListSlot){
        .{ .slot = .query, .title = .{ .text = params.title, .@"align" = .center, .inset = 1 } },
        .{ .slot = .entries },
    };
    const root: view.View(ListSlot) = .{
        .composition = .{ .center = .{} },
        .children = &.{inputSurface(ListSlot, .surface, .cells(params.box.width +| 2), .cells(params.box.height +| 4), &boxes)},
    };
    view.walk(ListSlot, &root, area, visitor);
}

/// An Overlay with a header row, a body, and a hint row: the Composer, the
/// submit progress, and the submit result.
pub const DialogSlot = enum { surface, header, body, hint };

pub const Dialog = struct {
    box: Box,
    body_padding: view.Edges = .{},
};

pub const composer: Dialog = .{ .box = .{ .width = 72, .height = 14 }, .body_padding = .{ .left = 1 } };
pub const submit_progress: Dialog = .{ .box = .{ .width = 40, .height = 5 }, .body_padding = .{ .top = 1 } };
pub const submit_result: Dialog = .{ .box = .{ .width = 48, .height = 6 }, .body_padding = .{ .top = 1 } };

pub fn dialog(params: Dialog, area: Rect, visitor: anytype) void {
    const root: view.View(DialogSlot) = .{
        .composition = .{ .center = .{} },
        .children = &.{overlaySurface(DialogSlot, params.box, .{
            .slot = .surface,
            .composition = .{ .flow = .{} },
            .children = &.{
                .{ .slot = .header, .height = .cells(1) },
                .{ .slot = .body, .padding = params.body_padding },
                .{ .slot = .hint, .height = .cells(1) },
            },
        })},
    };
    view.walk(DialogSlot, &root, area, visitor);
}

/// The boot and switch dialog: one line, centered.
pub const LoadingSlot = enum { surface, line };

pub fn loading(_: void, area: Rect, visitor: anytype) void {
    const root: view.View(LoadingSlot) = .{
        .composition = .{ .center = .{} },
        .children = &.{overlaySurface(LoadingSlot, .{ .width = 46, .height = 1 }, .{
            .slot = .surface,
            .composition = .{ .flow = .{} },
            .children = &.{.{ .slot = .line, .height = .cells(1) }},
        })},
    };
    view.walk(LoadingSlot, &root, area, visitor);
}

/// The keybinding help: Motions and commands in two columns, then the Mouse
/// notes and the hint row.
pub const HelpSlot = enum { surface, title, motions, commands, mouse, hint };

pub fn help(rows: usize, area: Rect, visitor: anytype) void {
    const root: view.View(HelpSlot) = .{
        .composition = .{ .center = .{} },
        .children = &.{overlaySurface(HelpSlot, .{ .width = 74, .height = @intCast(@min(rows + 5, 255)) }, .{
            .slot = .surface,
            .composition = .{ .flow = .{} },
            .children = &.{
                .{ .slot = .title, .height = .cells(1) },
                .{
                    .composition = .{ .flow = .{ .axis = .horizontal } },
                    .children = &.{
                        .{ .slot = .motions, .width = .fraction(1, 2), .padding = .{ .left = 2 } },
                        .{ .slot = .commands, .padding = .{ .left = 1 } },
                    },
                },
                .{ .slot = .mouse, .height = .cells(3), .padding = .{ .left = 1 } },
                .{ .slot = .hint, .height = .cells(1) },
            },
        })},
    };
    view.walk(HelpSlot, &root, area, visitor);
}

/// The Submission Overlay: a title, a summary, the Draft forest, and the
/// detail of the selected Draft.
pub const SubmissionSlot = enum { surface, title, summary, items, detail };

pub fn submission(_: void, area: Rect, visitor: anytype) void {
    const root: view.View(SubmissionSlot) = .{
        .composition = .{ .center = .{} },
        .children = &.{overlaySurface(SubmissionSlot, .{ .width = 78, .height = 22 }, .{
            .slot = .surface,
            .composition = .{ .flow = .{} },
            .children = &.{
                .{ .slot = .title, .height = .cells(1) },
                .{ .slot = .summary, .height = .cells(1) },
                .{ .slot = .items },
                .{ .slot = .detail, .height = .cells(6) },
            },
        })},
    };
    view.walk(SubmissionSlot, &root, area, visitor);
}

/// Review Search: the query box above the Results list and the Preview. The
/// list and the Preview sit side by side when the area is at least as wide
/// as it is tall, and stack otherwise.
pub const SearchSlot = enum { surface, search_box, query, body, list, divider, preview_column, header, preview };

pub const ReviewSearch = struct {
    status: []const u8 = "",
    results_title: []const u8 = "",
    list_scroll: Scroll = .{},
};

pub fn reviewSearch(params: ReviewSearch, area: Rect, visitor: anytype) void {
    const V = view.View(SearchSlot);
    const landscape = area.width >= area.height;
    const preview_title: view.Title = .{ .text = "Preview", .@"align" = .center, .inset = 1 };
    const preview_children = [_]V{
        .{ .slot = .header, .height = .cells(1) },
        .{ .composition = .{ .rule = overlay_stroke } },
        .{ .slot = .preview },
    };
    const list_size: Size = if (landscape) .fraction(3, 10) else .{ .basis = .{ .fraction = .{ .num = 3, .den = 10 } }, .min = 2 };
    const body_children = [_]V{
        .{
            .slot = .list,
            .width = list_size,
            .height = list_size,
            .title = .{ .text = params.results_title, .@"align" = .center, .inset = 1 },
            .scrollbar = bar(params.list_scroll, .padding, overlay_stroke),
        },
        .{ .slot = .divider, .composition = .{ .rule = overlay_stroke }, .title = if (landscape) null else preview_title },
        .{
            .slot = .preview_column,
            .title = if (landscape) preview_title else null,
            .composition = .{ .flow = .{} },
            .children = &preview_children,
        },
    };
    var boxes = [_]V{
        .{
            .slot = .search_box,
            .title = .{ .text = "Review Search", .@"align" = .center, .inset = 1 },
            .composition = .{ .flow = .{} },
            .children = &.{.{ .slot = .query, .title = .{ .text = params.status, .edge = .bottom, .@"align" = .end } }},
        },
        .{
            .slot = .body,
            .composition = .{ .flow = .{ .axis = if (landscape) .horizontal else .vertical } },
            .children = &body_children,
        },
    };
    const root: V = .{
        .composition = .{ .center = .{} },
        .children = &.{inputSurface(
            SearchSlot,
            .surface,
            .{ .basis = .{ .fraction = .{ .num = 4, .den = 5 } }, .min = 64 },
            .{ .basis = .{ .fraction = .{ .num = 4, .den = 5 } }, .min = 14 },
            &boxes,
        )},
    };
    view.walk(SearchSlot, &root, area, visitor);
}

const testing = std.testing;

test "every layout places each of its Slots" {
    const areas = [_]Rect{ .{}, .{ .width = 1, .height = 1 }, .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 100 } };
    for (areas) |area| {
        _ = view.solve(AppSlot, app, @as(u16, 3), area);
        _ = view.solve(StatusSlot, status, Status.initFill(9), area);
        _ = view.solve(PaneSlot, panes, Panes{ .diff_scroll = .{ .total = 100, .offset = 3 } }, area);
        _ = view.solve(ListSlot, listOverlay, ListOverlay{ .box = .{ .width = 60, .height = 16 } }, area);
        _ = view.solve(DialogSlot, dialog, composer, area);
        _ = view.solve(LoadingSlot, loading, {}, area);
        _ = view.solve(HelpSlot, help, @as(usize, 20), area);
        _ = view.solve(SubmissionSlot, submission, {}, area);
        _ = view.solve(SearchSlot, reviewSearch, ReviewSearch{ .list_scroll = .{ .total = 50, .offset = 0 } }, area);
    }
}

test "the Panes touch with no gap and a 28-cell Sidebar" {
    const wide = view.solve(PaneSlot, panes, Panes{}, .{ .width = 80, .height = 24 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 28, .height = 24 }, wide.get(.sidebar).border);
    try testing.expectEqual(Rect{ .x = 28, .y = 0, .width = 52, .height = 24 }, wide.get(.diff).border);
    try testing.expectEqual(Rect{ .x = 29, .y = 1, .width = 50, .height = 22 }, wide.get(.diff).content);
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 26, .height = 22 }, wide.get(.sidebar).content);
    const narrow = view.solve(PaneSlot, panes, Panes{}, .{ .width = 40, .height = 24 });
    try testing.expectEqual(narrow.get(.sidebar).border.width, narrow.get(.diff).border.x);
}

test "the status parts wrap by item and stack the hints under the meta information" {
    const params: Status = .initDefault(0, .{ .title = 20, .verdict = 8, .refs = 14, .position = 7, .layout = 7, .scope = 10, .isolate = 9, .comment = 11, .quit = 6 });
    const meta = [_]StatusSlot{ .title, .verdict, .refs, .position };
    const hints = [_]StatusSlot{ .layout, .scope, .isolate, .comment, .quit };

    try testing.expectEqual(@as(u16, 2), statusHeight(params, 120));
    const wide = statusRects(params, .{ .y = 30, .width = 120, .height = 2 });
    try testing.expectEqual(Rect{ .x = 1, .y = 30, .width = 20, .height = 1 }, wide.get(.title).content);
    try testing.expectEqual(Rect{ .x = 26, .y = 30, .width = 8, .height = 1 }, wide.get(.verdict).content);
    for (meta) |slot| try testing.expectEqual(@as(u16, 30), wide.get(slot).content.y);
    for (hints) |slot| try testing.expectEqual(@as(u16, 31), wide.get(slot).content.y);
    try testing.expect(wide.get(.search).content.isEmpty());
    try testing.expect(wide.get(.submit).content.isEmpty());

    const height = statusHeight(params, 30);
    try testing.expect(height > 4);
    const narrow = statusRects(params, .{ .y = 5, .width = 30, .height = height });
    var bottom: u16 = 0;
    var last_meta: u16 = 0;
    for (meta ++ hints) |slot| {
        const rect = narrow.get(slot).content;
        try testing.expectEqual(params.get(slot), rect.width);
        try testing.expect(rect.x >= 1 and rect.x + rect.width <= 29);
        bottom = @max(bottom, rect.y + rect.height);
        if (std.mem.indexOfScalar(StatusSlot, &meta, slot) != null) last_meta = @max(last_meta, rect.y);
    }
    try testing.expect(last_meta > 5);
    for (hints) |slot| try testing.expect(narrow.get(slot).content.y > last_meta);
    try testing.expectEqual(height, bottom - 5);
}

test "the Help columns start at column 2 and one cell after the middle" {
    const rects = view.solve(HelpSlot, help, @as(usize, 10), .{ .width = 100, .height = 40 });
    const surface = rects.get(.surface).content;
    try testing.expectEqual(surface.x + 2, rects.get(.motions).content.x);
    try testing.expectEqual(surface.x + surface.width / 2 + 1, rects.get(.commands).content.x);
    try testing.expectEqual(surface.y + 1, rects.get(.motions).content.y);
}
