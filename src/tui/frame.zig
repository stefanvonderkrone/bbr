//! Atomic, terminal-independent Presentation Frame metadata.

const std = @import("std");
const bbr = @import("bbr");
const Nav = @import("nav.zig").Nav;
const buffer_mod = @import("buffer.zig");

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

/// Projection depends on this portable seam, never on vaxis's active width
/// method. The adapter may inject the terminal's grapheme/cell implementation.
pub const CellMetrics = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        width: *const fn (ptr: *const anyopaque, text: []const u8) usize,
    };

    pub fn width(self: CellMetrics, text: []const u8) usize {
        return self.vtable.width(self.ptr, text);
    }

    pub const bytes: CellMetrics = .{ .ptr = &byte_context, .vtable = &byte_vtable };
    const byte_context: u8 = 0;
    const byte_vtable: VTable = .{ .width = byteWidth };
    fn byteWidth(_: *const anyopaque, text: []const u8) usize {
        return text.len;
    }
};

pub const RowOwner = union(enum) {
    file: *const bbr.diff.File,
    hunk: *const bbr.diff.model.Hunk,
    line: *const bbr.diff.Line,
    fold: *const bbr.diff.Line,
    comment: struct { id: bbr.review.CommentId, source_offset: usize },
    draft: struct { id: bbr.review.TempId, source_offset: usize },
    snapshot: struct { id: bbr.review.TempId, source_offset: usize },
    section: struct { kind: buffer_mod.SectionKind, path: []const u8 },

    pub fn eql(a: RowOwner, b: RowOwner) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .file => |value| value == b.file,
            .hunk => |value| value == b.hunk,
            .line => |value| value == b.line,
            .fold => |value| value == b.fold,
            .comment => |value| value.id == b.comment.id and value.source_offset == b.comment.source_offset,
            .draft => |value| value.id == b.draft.id and value.source_offset == b.draft.source_offset,
            .snapshot => |value| value.id == b.snapshot.id and value.source_offset == b.snapshot.source_offset,
            .section => |value| value.kind == b.section.kind and std.mem.eql(u8, value.path, b.section.path),
        };
    }
};

pub const SemanticTarget = struct {
    owner: RowOwner,
    measured_cells: usize,
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
        .measured_cells = metrics.width(rowText(row)),
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
        .fold => |fold| .{ .fold = fold.id },
        .comment => |comment| .{ .comment = .{ .id = comment.comment.id, .source_offset = sourceOffset(comment.comment.body, comment.line) } },
        .draft => |draft| .{ .draft = .{ .id = draft.draft.local_id, .source_offset = sourceOffset(draft.draft.body, draft.line) } },
        .snapshot => |snapshot| .{ .snapshot = .{ .id = snapshot.draft.local_id, .source_offset = if (snapshot.draft.snapshot) |value| sourceOffset(value.text, snapshot.line) else 0 } },
        .section => |section| .{ .section = .{ .kind = section.kind, .path = section.path } },
    };
}

fn rowText(row: buffer_mod.Row) []const u8 {
    return switch (row) {
        .file_header => |file| file.displayPath(),
        .hunk_header => |hunk| hunk.header,
        .line => |line| line.line.text,
        .line_pair => |pair| if (pair.right) |right| right.line.text else if (pair.left) |left| left.line.text else "",
        .fold => "",
        .comment => |comment| comment.line,
        .draft => |draft| draft.line,
        .snapshot => |snapshot| snapshot.line,
        .section => |section| section.path,
    };
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

        fn cellWidth(ptr: *const anyopaque, text: []const u8) usize {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ptr)));
            self.calls += 1;
            return if (std.mem.eql(u8, text, "wide")) 2 else 0;
        }
    };
    const vtable: CellMetrics.VTable = .{ .width = Metrics.cellWidth };
    var metrics_context: Metrics = .{};
    const metrics: CellMetrics = .{ .ptr = &metrics_context, .vtable = &vtable };
    const rows = [_]buffer_mod.Row{.{ .section = .{ .kind = .outdated, .count = 1, .path = "wide" } }};

    const targets = try buildTargets(testing.allocator, &rows, metrics);
    defer testing.allocator.free(targets);

    try testing.expectEqual(@as(usize, 1), metrics_context.calls);
    try testing.expectEqual(@as(usize, 2), targets[0].measured_cells);
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
