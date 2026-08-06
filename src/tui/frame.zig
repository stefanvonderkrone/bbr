//! Atomic, terminal-independent Presentation Frame metadata.

const std = @import("std");
const bbr = @import("bbr");
const Nav = @import("nav.zig").Nav;
const buffer_mod = @import("buffer.zig");
pub const CellMetrics = @import("cell_metrics.zig").CellMetrics;

pub const Revision = u64;

pub const Geometry = struct {
    cols: u16,
    rows: u16,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.x and row >= self.y and
            col - self.x < self.width and row - self.y < self.height;
    }
};

pub const PaneRects = struct {
    sidebar: Rect,
    diff: Rect,
};

pub const RowOwner = union(enum) {
    file: *const bbr.diff.File,
    hunk: *const bbr.diff.model.Hunk,
    line: *const bbr.diff.Line,
    disclosure: buffer_mod.DisclosureKey,
    comment: struct { id: bbr.review.CommentId, source_offset: usize, part: ?@import("review_card.zig").Part = null },
    draft: struct { id: bbr.review.TempId, source_offset: usize, part: ?@import("review_card.zig").Part = null },
    snapshot: struct { id: bbr.review.TempId, source_offset: usize },
    section: struct { kind: buffer_mod.SectionKind, path: []const u8 },

    pub fn eql(a: RowOwner, b: RowOwner) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .file => |value| value == b.file,
            .hunk => |value| value == b.hunk,
            .line => |value| value == b.line,
            .disclosure => |value| std.meta.eql(value, b.disclosure),
            .comment => |value| value.id == b.comment.id and value.source_offset == b.comment.source_offset and value.part == b.comment.part,
            .draft => |value| value.id == b.draft.id and value.source_offset == b.draft.source_offset and value.part == b.draft.part,
            .snapshot => |value| value.id == b.snapshot.id and value.source_offset == b.snapshot.source_offset,
            .section => |value| value.kind == b.section.kind and std.mem.eql(u8, value.path, b.section.path),
        };
    }
};

pub const SemanticTarget = struct {
    owner: RowOwner,
    measured_cells: usize,
    source_end: usize = 0,
};

pub const Projection = struct {
    revision: Revision,
    targets_revision: Revision,
    geometry: Geometry,
    panes: PaneRects,
    overlays: []const Rect,
    targets: []const SemanticTarget,
    buffer: buffer_mod.Buffer,
    navigation: Nav,
};

pub fn paneRects(geometry: Geometry) PaneRects {
    const sidebar_width: u16 = @min(28, geometry.cols);
    const diff_x: u16 = @min(sidebar_width +| 1, geometry.cols);
    return .{
        .sidebar = .{ .x = 0, .y = 0, .width = sidebar_width, .height = geometry.rows },
        .diff = .{ .x = diff_x, .y = 0, .width = geometry.cols - diff_x, .height = geometry.rows },
    };
}

pub fn buildTargets(
    allocator: std.mem.Allocator,
    rows: []const buffer_mod.Row,
    metrics: CellMetrics,
) ![]const SemanticTarget {
    const targets = try allocator.alloc(SemanticTarget, rows.len);
    for (rows, targets) |row, *target| target.* = .{
        .owner = owner(row),
        .measured_cells = rowWidth(row, metrics),
        .source_end = rowSourceEnd(row),
    };
    return targets;
}

pub fn restoreNavigation(previous: Projection, targets: []const SemanticTarget, geometry: Geometry) Nav {
    var restored = Nav.init(targets.len, geometry.rows);
    restored.count = previous.navigation.count;
    const cursor_owner = targetOwner(previous.targets, previous.navigation.cursor) orelse return restored;
    const cursor = findOwner(targets, cursor_owner) orelse return restored;
    restored.jumpTo(cursor);
    restored.count = previous.navigation.count;

    const old_offset = previous.navigation.cursor -| previous.navigation.scroll;
    restored.scroll = cursor -| old_offset;
    restored.setViewport(geometry.rows);

    if (previous.navigation.mark) |mark| {
        const mark_owner = targetOwner(previous.targets, mark) orelse return restored;
        const restored_mark = findOwner(targets, mark_owner) orelse return restored;
        const old_range = [2]usize{ @min(mark, previous.navigation.cursor), @max(mark, previous.navigation.cursor) };
        const new_range = [2]usize{ @min(restored_mark, cursor), @max(restored_mark, cursor) };
        if (std.meta.eql(old_range, new_range)) restored.mark = restored_mark;
    }
    return restored;
}

fn findOwner(targets: []const SemanticTarget, wanted: RowOwner) ?usize {
    for (targets, 0..) |target, index| if (target.owner.eql(wanted)) return index;
    // Width changes alter projected row starts. Restore a ReviewCard to the
    // same source offset's containing row, or the nearest following row. A
    // collapsed card's footer uses the body-end offset, so hidden content lands
    // on that disclosure instead of another item.
    var nearest: ?usize = null;
    var nearest_offset: usize = std.math.maxInt(usize);
    for (targets, 0..) |target, index| switch (wanted) {
        .comment => |value| if (target.owner == .comment and target.owner.comment.id == value.id and target.owner.comment.part != .header and ((target.owner.comment.source_offset <= value.source_offset and value.source_offset < target.source_end) or target.owner.comment.source_offset >= value.source_offset) and target.owner.comment.source_offset < nearest_offset) {
            nearest = index;
            nearest_offset = target.owner.comment.source_offset;
        },
        .draft => |value| if (target.owner == .draft and target.owner.draft.id == value.id and target.owner.draft.part != .header and ((target.owner.draft.source_offset <= value.source_offset and value.source_offset < target.source_end) or target.owner.draft.source_offset >= value.source_offset) and target.owner.draft.source_offset < nearest_offset) {
            nearest = index;
            nearest_offset = target.owner.draft.source_offset;
        },
        else => {},
    };
    if (nearest) |index| return index;
    return null;
}

fn targetOwner(targets: []const SemanticTarget, index: usize) ?RowOwner {
    if (index >= targets.len) return null;
    return targets[index].owner;
}

fn owner(row: buffer_mod.Row) RowOwner {
    return switch (row) {
        .file_header => |file| .{ .file = file },
        .hunk_header => |hunk| .{ .hunk = hunk },
        .line => |line| .{ .line = line.line },
        .line_pair => |pair| .{ .line = if (pair.right) |right| right.line else pair.left.?.line },
        .disclosure => |value| .{ .disclosure = value.key },
        .comment => |card| switch (card.owner) {
            .comment => |id| .{ .comment = .{ .id = id, .source_offset = card.source_range.start, .part = anchorPart(card.part) } },
            else => unreachable,
        },
        .draft => |card| switch (card.owner) {
            .draft => |id| .{ .draft = .{ .id = id, .source_offset = card.source_range.start, .part = anchorPart(card.part) } },
            else => unreachable,
        },
        .snapshot => |snapshot| .{ .snapshot = .{ .id = snapshot.draft.local_id, .source_offset = if (snapshot.draft.snapshot) |value| sourceOffset(value.text, snapshot.line) else 0 } },
        .section => |section| .{ .section = .{ .kind = section.kind, .path = section.path } },
    };
}

fn anchorPart(part: @import("review_card.zig").Part) ?@import("review_card.zig").Part {
    return switch (part) {
        .header, .disclosure_footer => part,
        else => null,
    };
}

fn rowSourceEnd(row: buffer_mod.Row) usize {
    return switch (row) {
        .comment => |card| card.source_range.end,
        .draft => |card| card.source_range.end,
        else => 0,
    };
}

fn rowText(row: buffer_mod.Row) []const u8 {
    return switch (row) {
        .file_header => |file| file.displayPath(),
        .hunk_header => |hunk| hunk.header,
        .line => |line| line.line.text,
        .line_pair => |pair| if (pair.right) |right| right.line.text else if (pair.left) |left| left.line.text else "",
        .disclosure => "",
        .comment => |card| card.text(),
        .draft => |card| card.text(),
        .snapshot => |snapshot| snapshot.line,
        .section => |section| section.path,
    };
}

fn rowWidth(row: buffer_mod.Row, metrics: CellMetrics) usize {
    return switch (row) {
        .comment => |card| segmentsWidth(card.segments, metrics),
        .draft => |card| segmentsWidth(card.segments, metrics),
        else => metrics.width(rowText(row)),
    };
}

fn segmentsWidth(segments: []const @import("review_card.zig").Segment, metrics: CellMetrics) usize {
    var width: usize = 0;
    for (segments) |segment| width += metrics.width(segment.text);
    return width;
}

fn sourceOffset(source: []const u8, part: []const u8) usize {
    const source_start = @intFromPtr(source.ptr);
    const part_start = @intFromPtr(part.ptr);
    if (part_start < source_start or part_start > source_start + source.len) return 0;
    return part_start - source_start;
}

const testing = std.testing;

test "semantic targets use the injected CellMetrics seam" {
    const Metrics = struct {
        calls: usize = 0,

        fn next(ptr: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ptr)));
            self.calls += 1;
            return .{ .byte_len = if (text.len == 0) 0 else 1, .cell_width = if (text.len > 0 and text[0] == 'w') 2 else 1 };
        }
    };
    const vtable: CellMetrics.VTable = .{ .next = Metrics.next };
    var metrics_context: Metrics = .{};
    const metrics: CellMetrics = .{ .ptr = &metrics_context, .vtable = &vtable };
    const rows = [_]buffer_mod.Row{.{ .section = .{ .kind = .outdated, .count = 1, .path = "wide" } }};

    const targets = try buildTargets(testing.allocator, &rows, metrics);
    defer testing.allocator.free(targets);

    try testing.expectEqual(@as(usize, 4), metrics_context.calls);
    try testing.expectEqual(@as(usize, 5), targets[0].measured_cells);
}

test "navigation restoration follows stable owners and clears a shifted Selection" {
    const old_targets = [_]SemanticTarget{
        .{ .owner = .{ .section = .{ .kind = .pr_comments, .path = "" } }, .measured_cells = 0 },
        .{ .owner = .{ .section = .{ .kind = .outdated, .path = "a.zig" } }, .measured_cells = 5 },
    };
    const new_targets = [_]SemanticTarget{
        .{ .owner = .{ .section = .{ .kind = .pending, .path = "" } }, .measured_cells = 0 },
        old_targets[0],
        old_targets[1],
    };
    var navigation = Nav.init(old_targets.len, 4);
    navigation.cursor = 1;
    navigation.mark = 0;
    navigation.count = 7;
    const previous: Projection = .{
        .revision = 4,
        .targets_revision = 4,
        .geometry = .{ .cols = 80, .rows = 4 },
        .panes = paneRects(.{ .cols = 80, .rows = 4 }),
        .overlays = &.{},
        .targets = &old_targets,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = navigation,
    };

    const restored = restoreNavigation(previous, &new_targets, .{ .cols = 60, .rows = 3 });

    try testing.expectEqual(@as(usize, 2), restored.cursor);
    try testing.expectEqual(@as(usize, 7), restored.count);
    try testing.expectEqual(@as(usize, 3), restored.viewport);
    try testing.expect(restored.mark == null);
}

test "ReviewCard restoration follows containing source offset and collapsed footer" {
    const old_targets = [_]SemanticTarget{
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } }, .measured_cells = 5 },
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 8 } }, .measured_cells = 10, .source_end = 18 },
    };
    var navigation = Nav.init(old_targets.len, 3);
    navigation.cursor = 1;
    const previous: Projection = .{
        .revision = 1,
        .targets_revision = 1,
        .geometry = .{ .cols = 40, .rows = 3 },
        .panes = paneRects(.{ .cols = 40, .rows = 3 }),
        .overlays = &.{},
        .targets = &old_targets,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = navigation,
    };
    const resized = [_]SemanticTarget{
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } }, .measured_cells = 5 },
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 4 } }, .measured_cells = 18, .source_end = 14 },
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 14 } }, .measured_cells = 4, .source_end = 18 },
    };
    try testing.expectEqual(@as(usize, 1), restoreNavigation(previous, &resized, .{ .cols = 60, .rows = 3 }).cursor);

    const collapsed = [_]SemanticTarget{
        resized[0],
        .{ .owner = .{ .comment = .{ .id = 7, .source_offset = 18, .part = .disclosure_footer } }, .measured_cells = 20, .source_end = 18 },
    };
    try testing.expectEqual(@as(usize, 1), restoreNavigation(previous, &collapsed, .{ .cols = 30, .rows = 3 }).cursor);
}
