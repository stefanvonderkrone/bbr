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

/// The terminal window: the content area above one status row.
pub const AppSlot = enum { content, status };

pub fn app(_: void, area: Rect, visitor: anytype) void {
    const root: view.View(AppSlot) = .{
        .composition = .{ .flow = .{} },
        .children = &.{ .{ .slot = .content }, .{ .slot = .status, .height = .cells(1) } },
    };
    view.walk(AppSlot, &root, area, visitor);
}

/// The status row: the review identity at the start and the key hints at the
/// end. When both do not fit, the hints shrink.
pub const StatusSlot = enum { start, end };

pub const Status = struct {
    /// Cell widths of the two texts.
    start: u16,
    end: u16 = 0,
    padding: u16 = 1,
};

pub fn status(params: Status, area: Rect, visitor: anytype) void {
    const root: view.View(StatusSlot) = .{
        .padding = view.Edges.sides(params.padding),
        .composition = .{ .repel = .{ .gap = 2, .wrap = false } },
        .children = &.{ .{ .slot = .start, .width = .cells(params.start) }, .{ .slot = .end, .width = .cells(params.end) } },
    };
    view.walk(StatusSlot, &root, area, visitor);
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
        .composition = .{ .sidebar = .{ .content_min = 3, .gap = if (area.width >= 60) 1 else 0, .wrap = false } },
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

/// The one way to build an Overlay surface: a filled box with a rounded
/// border around `box` content cells, centered in its area.
fn overlaySurface(comptime Slot: type, box: Box, node: view.View(Slot)) view.View(Slot) {
    var result = node;
    result.width = .cells(box.width +| 2);
    result.height = .cells(box.height +| 2);
    result.fill = .surface;
    result.border = .{ .stroke = overlay_stroke };
    return result;
}

/// A List Overlay: the query row above the ranked entries.
pub const ListSlot = enum { surface, query, entries };

pub fn listOverlay(box: Box, area: Rect, visitor: anytype) void {
    const root: view.View(ListSlot) = .{
        .composition = .{ .center = .{} },
        .children = &.{overlaySurface(ListSlot, box, .{
            .slot = .surface,
            .composition = .{ .flow = .{} },
            .children = &.{
                .{ .slot = .query, .height = .cells(1), .fill = .header },
                .{ .slot = .entries },
            },
        })},
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
                .{ .slot = .header, .height = .cells(1), .fill = .header },
                .{ .slot = .body, .padding = params.body_padding },
                .{ .slot = .hint, .height = .cells(1), .fill = .header },
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
                .{ .slot = .title, .height = .cells(1), .fill = .header },
                .{
                    .composition = .{ .flow = .{ .axis = .horizontal } },
                    .children = &.{
                        .{ .slot = .motions, .width = .fraction(1, 2), .padding = .{ .left = 2 } },
                        .{ .slot = .commands, .padding = .{ .left = 1 } },
                    },
                },
                .{ .slot = .mouse, .height = .cells(3), .padding = .{ .left = 1 } },
                .{ .slot = .hint, .height = .cells(1), .fill = .header },
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
                .{ .slot = .title, .height = .cells(1), .fill = .header },
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
    const root: V = .{
        .composition = .{ .center = .{} },
        .children = &.{.{
            .slot = .surface,
            .width = .{ .basis = .{ .fraction = .{ .num = 4, .den = 5 } }, .min = 64 },
            .height = .{ .basis = .{ .fraction = .{ .num = 4, .den = 5 } }, .min = 14 },
            .fill = .surface,
            .composition = .{ .flow = .{} },
            .children = &.{
                .{
                    .slot = .search_box,
                    .height = .cells(3),
                    .border = .{ .stroke = overlay_stroke },
                    .title = .{ .text = "Review Search", .@"align" = .center, .inset = 1 },
                    .composition = .{ .flow = .{} },
                    .children = &.{.{ .slot = .query, .title = .{ .text = params.status, .edge = .bottom, .@"align" = .end } }},
                },
                .{
                    .slot = .body,
                    .border = .{ .stroke = overlay_stroke },
                    .composition = .{ .flow = .{ .axis = if (landscape) .horizontal else .vertical } },
                    .children = &body_children,
                },
            },
        }},
    };
    view.walk(SearchSlot, &root, area, visitor);
}

const testing = std.testing;

test "every layout places each of its Slots" {
    const areas = [_]Rect{ .{}, .{ .width = 1, .height = 1 }, .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 100 } };
    for (areas) |area| {
        _ = view.solve(AppSlot, app, {}, area);
        _ = view.solve(StatusSlot, status, Status{ .start = 30, .end = 60 }, area);
        _ = view.solve(PaneSlot, panes, Panes{ .diff_scroll = .{ .total = 100, .offset = 3 } }, area);
        _ = view.solve(ListSlot, listOverlay, Box{ .width = 60, .height = 16 }, area);
        _ = view.solve(DialogSlot, dialog, composer, area);
        _ = view.solve(LoadingSlot, loading, {}, area);
        _ = view.solve(HelpSlot, help, @as(usize, 20), area);
        _ = view.solve(SubmissionSlot, submission, {}, area);
        _ = view.solve(SearchSlot, reviewSearch, ReviewSearch{ .list_scroll = .{ .total = 50, .offset = 0 } }, area);
    }
}

test "the Panes keep a one-cell gap from 60 columns and a 28-cell Sidebar" {
    const wide = view.solve(PaneSlot, panes, Panes{}, .{ .width = 80, .height = 24 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 28, .height = 24 }, wide.get(.sidebar).border);
    try testing.expectEqual(Rect{ .x = 29, .y = 0, .width = 51, .height = 24 }, wide.get(.diff).border);
    try testing.expectEqual(Rect{ .x = 30, .y = 1, .width = 49, .height = 22 }, wide.get(.diff).content);
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 26, .height = 22 }, wide.get(.sidebar).content);
    const narrow = view.solve(PaneSlot, panes, Panes{}, .{ .width = 40, .height = 24 });
    try testing.expectEqual(narrow.get(.sidebar).border.width, narrow.get(.diff).border.x);
}

test "the status row puts the hints at the end and shrinks them first" {
    const wide = view.solve(StatusSlot, status, Status{ .start = 10, .end = 20 }, .{ .y = 9, .width = 80, .height = 1 });
    try testing.expectEqual(Rect{ .x = 1, .y = 9, .width = 10, .height = 1 }, wide.get(.start).content);
    try testing.expectEqual(Rect{ .x = 59, .y = 9, .width = 20, .height = 1 }, wide.get(.end).content);
    const narrow = view.solve(StatusSlot, status, Status{ .start = 10, .end = 20 }, .{ .width = 24, .height = 1 });
    try testing.expectEqual(Rect{ .x = 1, .y = 0, .width = 10, .height = 1 }, narrow.get(.start).content);
    try testing.expectEqual(Rect{ .x = 13, .y = 0, .width = 10, .height = 1 }, narrow.get(.end).content);
}

test "the Help columns start at column 2 and one cell after the middle" {
    const rects = view.solve(HelpSlot, help, @as(usize, 10), .{ .width = 100, .height = 40 });
    const surface = rects.get(.surface).content;
    try testing.expectEqual(surface.x + 2, rects.get(.motions).content.x);
    try testing.expectEqual(surface.x + surface.width / 2 + 1, rects.get(.commands).content.x);
    try testing.expectEqual(surface.y + 1, rects.get(.motions).content.y);
}
