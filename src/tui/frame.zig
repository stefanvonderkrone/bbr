//! Atomic, terminal-independent Presentation Frame metadata.

const std = @import("std");
const bbr = @import("bbr");
const Nav = @import("nav.zig").Nav;
const buffer_mod = @import("buffer.zig");
pub const file_tree = @import("file_tree.zig");
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
    sidebar_content: Rect,
    diff_content: Rect,
};

pub const PaneFocus = enum { sidebar, diff };

pub const OverlayKind = enum { picker, other };

pub const OverlayTarget = struct {
    kind: OverlayKind,
    rect: Rect,
    row_count: usize = 0,
    scroll: usize = 0,
};

pub const HitTarget = union(enum) {
    sidebar,
    diff,
    sidebar_entry: usize,
    diff_row: usize,
    picker_entry: usize,
};

pub const RowOwner = union(enum) {
    file: *const bbr.diff.File,
    hunk: *const bbr.diff.model.Hunk,
    status_placeholder: struct { file: *const bbr.diff.File, old: bool, new: bool },
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
            .status_placeholder => |value| value.file == b.status_placeholder.file and value.old == b.status_placeholder.old and value.new == b.status_placeholder.new,
            .line => |value| value == b.line,
            .disclosure => |value| std.meta.eql(value, b.disclosure),
            .comment => |value| value.id == b.comment.id and value.source_offset == b.comment.source_offset and value.part == b.comment.part,
            .draft => |value| value.id == b.draft.id and value.source_offset == b.draft.source_offset and value.part == b.draft.part,
            .snapshot => |value| value.id == b.snapshot.id and value.source_offset == b.snapshot.source_offset,
            .section => |value| value.kind == b.section.kind and std.mem.eql(u8, value.path, b.section.path),
        };
    }
};

/// One geometry-dependent DiffPane row. `row` retains the width-independent
/// Buffer owner while byte bounds and decoration describe this projection.
pub const VisualRow = struct {
    row: buffer_mod.Row,
    buffer_index: usize = 0,
    owner: RowOwner,
    measured_cells: usize,
    source_start: usize = 0,
    source_end: usize = 0,
    decoration: ?bbr.highlight.LineDecoration = null,
    continuation: bool = false,
};

pub const VisualRowOptions = struct {
    layout: buffer_mod.Layout,
    width: usize,
    wrap: bool,
};

pub const Projection = struct {
    revision: Revision,
    visual_rows_revision: Revision,
    geometry: Geometry,
    panes: PaneRects,
    overlay: ?OverlayTarget = null,
    visual_rows: []const VisualRow,
    buffer: buffer_mod.Buffer,
    navigation: Nav,
    file_tree: file_tree.Projection = .{},
    focus: PaneFocus = .diff,
};

/// Resolve a cell solely against the immutable, already-published Frame. An
/// Overlay captures the complete input surface, even outside its rectangle.
pub fn hitTest(frame: Projection, col: u16, row: u16) ?HitTarget {
    if (frame.overlay) |overlay| {
        if (overlay.kind != .picker or !overlay.rect.contains(col, row)) return null;
        const relative_row = row - overlay.rect.y;
        if (relative_row == 0) return null; // query/title row
        const index = overlay.scroll + relative_row - 1;
        if (index >= overlay.row_count) return null;
        return .{ .picker_entry = index };
    }

    if (frame.panes.sidebar_content.contains(col, row)) {
        const index = frame.file_tree.scroll + row - frame.panes.sidebar_content.y;
        if (index < frame.file_tree.entries.len) return .{ .sidebar_entry = index };
        return .sidebar;
    }
    if (frame.panes.diff_content.contains(col, row)) {
        const index = frame.navigation.scroll + row - frame.panes.diff_content.y;
        if (index < frame.visual_rows.len) return .{ .diff_row = index };
        return .diff;
    }
    return null;
}

pub fn paneRects(geometry: Geometry) PaneRects {
    const gap: u16 = if (geometry.cols >= 60) 1 else 0;
    const sidebar_width: u16 = if (geometry.cols < 6) geometry.cols / 2 else @min(28, geometry.cols - 3 - gap);
    const diff_x: u16 = @min(sidebar_width +| gap, geometry.cols);
    const diff_width = geometry.cols - diff_x;
    const sidebar: Rect = .{ .x = 0, .y = 0, .width = sidebar_width, .height = geometry.rows };
    const diff: Rect = .{ .x = diff_x, .y = 0, .width = diff_width, .height = geometry.rows };
    return .{
        .sidebar = sidebar,
        .diff = diff,
        .sidebar_content = paneContent(sidebar),
        .diff_content = paneContent(diff),
    };
}

/// Shared centered Overlay geometry used by both rendering and semantic input
/// targeting. A zero-sized Frame has no targetable Overlay.
pub fn overlayRect(geometry: Geometry, max_width: u16, max_height: u16) ?Rect {
    const width = @min(max_width, geometry.cols);
    const height = @min(max_height, geometry.rows);
    if (width == 0 or height == 0) return null;
    return .{
        .x = (geometry.cols - width) / 2,
        .y = (geometry.rows - height) / 2,
        .width = width,
        .height = height,
    };
}

fn paneContent(rect: Rect) Rect {
    return .{
        .x = rect.x +| @min(rect.width, 1),
        .y = rect.y +| @min(rect.height, 2),
        .width = rect.width -| 2,
        .height = rect.height -| 3,
    };
}

pub fn buildVisualRowsWithOptions(
    allocator: std.mem.Allocator,
    rows: []const buffer_mod.Row,
    metrics: CellMetrics,
    options: VisualRowOptions,
) ![]const VisualRow {
    if (!options.wrap or options.layout != .unified or options.width <= unified_gutter_cols) {
        return buildUnwrappedVisualRows(allocator, rows, metrics);
    }

    var visual_rows: std.ArrayList(VisualRow) = .empty;
    errdefer {
        for (visual_rows.items) |visual_row| if (visual_row.row == .line and visual_row.row.line.line.text.len > 0)
            if (visual_row.decoration) |decoration| if (decoration.runs.len > 0) allocator.free(decoration.runs);
        visual_rows.deinit(allocator);
    }
    const body_width = options.width - unified_gutter_cols;
    for (rows, 0..) |row, buffer_index| switch (row) {
        .line => |line_row| {
            if (line_row.line.text.len == 0) {
                try visual_rows.append(allocator, makeVisualRow(row, buffer_index, metrics));
                continue;
            }
            var start: usize = 0;
            while (start < line_row.line.text.len) {
                const end = wrapEnd(line_row.line.text, start, body_width, metrics);
                try appendWrappedVisualRow(allocator, &visual_rows, row, buffer_index, line_row, start, end, metrics);
                start = end;
            }
        },
        else => try visual_rows.append(allocator, makeVisualRow(row, buffer_index, metrics)),
    };
    return visual_rows.toOwnedSlice(allocator);
}

fn appendWrappedVisualRow(
    allocator: std.mem.Allocator,
    visual_rows: *std.ArrayList(VisualRow),
    row: buffer_mod.Row,
    buffer_index: usize,
    line_row: buffer_mod.LineRow,
    start: usize,
    end: usize,
    metrics: CellMetrics,
) !void {
    const decoration = try sliceDecoration(allocator, line_row.decoration, start, end);
    errdefer if (decoration.runs.len > 0) allocator.free(decoration.runs);
    try visual_rows.append(allocator, .{
        .row = row,
        .buffer_index = buffer_index,
        .owner = owner(row),
        .measured_cells = metrics.width(line_row.line.text[start..end]),
        .source_start = start,
        .source_end = end,
        .decoration = decoration,
        .continuation = start != 0,
    });
}

fn buildUnwrappedVisualRows(allocator: std.mem.Allocator, rows: []const buffer_mod.Row, metrics: CellMetrics) ![]const VisualRow {
    const visual_rows = try allocator.alloc(VisualRow, rows.len);
    for (rows, visual_rows, 0..) |row, *visual_row, buffer_index| visual_row.* = makeVisualRow(row, buffer_index, metrics);
    return visual_rows;
}

fn makeVisualRow(row: buffer_mod.Row, buffer_index: usize, metrics: CellMetrics) VisualRow {
    return .{
        .row = row,
        .buffer_index = buffer_index,
        .owner = owner(row),
        .measured_cells = rowWidth(row, metrics),
        .source_start = rowSourceStart(row),
        .source_end = rowSourceEnd(row),
        .decoration = rowDecoration(row),
    };
}

pub const unified_gutter_cols: usize = 10;

fn wrapEnd(text: []const u8, start: usize, width: usize, metrics: CellMetrics) usize {
    var pos = start;
    var cells: usize = 0;
    var whitespace_end: ?usize = null;
    while (pos < text.len) {
        const measured = metrics.next(text[pos..]);
        if (cells + measured.cell_width > width) {
            if (whitespace_end) |end| if (end > start) return end;
            return if (pos > start) pos else @min(pos + measured.byte_len, text.len);
        }
        pos += measured.byte_len;
        cells += measured.cell_width;
        if (isUnicodeWhitespace(text[pos - measured.byte_len .. pos])) whitespace_end = pos;
    }
    return text.len;
}

fn isUnicodeWhitespace(grapheme: []const u8) bool {
    const first_len = std.unicode.utf8ByteSequenceLength(grapheme[0]) catch return false;
    if (first_len > grapheme.len) return false;
    const cp = std.unicode.utf8Decode(grapheme[0..first_len]) catch return false;
    return (cp >= 0x09 and cp <= 0x0d) or cp == 0x20 or cp == 0x85 or cp == 0xa0 or
        cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or
        cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn sliceDecoration(
    allocator: std.mem.Allocator,
    decoration: bbr.highlight.LineDecoration,
    start: usize,
    end: usize,
) !bbr.highlight.LineDecoration {
    var count: usize = 0;
    var offset: usize = 0;
    for (decoration.runs) |run| {
        const run_end = offset + run.text.len;
        if (offset < end and run_end > start) count += 1;
        offset = run_end;
    }
    if (count == 0) return .{ .runs = &.{} };
    const runs = try allocator.alloc(bbr.highlight.decoration.Run, count);
    offset = 0;
    var index: usize = 0;
    for (decoration.runs) |run| {
        const run_end = offset + run.text.len;
        const overlap_start = @max(offset, start);
        const overlap_end = @min(run_end, end);
        if (overlap_start < overlap_end) {
            runs[index] = run;
            runs[index].text = run.text[overlap_start - offset .. overlap_end - offset];
            index += 1;
        }
        offset = run_end;
    }
    return .{ .runs = runs };
}

pub fn restoreNavigation(previous: Projection, visual_rows: []const VisualRow, geometry: Geometry) Nav {
    var restored = Nav.init(visual_rows.len, paneRects(geometry).diff_content.height);
    restored.count = previous.navigation.count;
    const cursor_row = visualRowAt(previous.visual_rows, previous.navigation.cursor) orelse return restored;
    const cursor = findVisualRow(visual_rows, cursor_row) orelse return restored;
    restored.jumpTo(cursor);
    restored.count = previous.navigation.count;

    const old_offset = previous.navigation.cursor -| previous.navigation.scroll;
    restored.scroll = cursor -| old_offset;
    restored.setViewport(paneRects(geometry).diff_content.height);

    if (previous.navigation.mark) |mark| {
        const mark_row = visualRowAt(previous.visual_rows, mark) orelse return restored;
        const restored_mark = findVisualRow(visual_rows, mark_row) orelse return restored;
        const old_range = [2]usize{ @min(mark, previous.navigation.cursor), @max(mark, previous.navigation.cursor) };
        const new_range = [2]usize{ @min(restored_mark, cursor), @max(restored_mark, cursor) };
        if ((mark_row.owner == .line and cursor_row.owner == .line) or std.meta.eql(old_range, new_range)) restored.mark = restored_mark;
    }
    return restored;
}

fn findVisualRow(visual_rows: []const VisualRow, wanted: VisualRow) ?usize {
    if (wanted.owner != .line) return findOwner(visual_rows, wanted.owner);
    var following: ?usize = null;
    var final: ?usize = null;
    for (visual_rows, 0..) |visual_row, index| {
        if (!visual_row.owner.eql(wanted.owner)) continue;
        final = index;
        if (visual_row.source_start <= wanted.source_start and wanted.source_start < visual_row.source_end) return index;
        if (following == null and visual_row.source_start >= wanted.source_start) following = index;
    }
    return following orelse final;
}

fn findOwner(visual_rows: []const VisualRow, wanted: RowOwner) ?usize {
    for (visual_rows, 0..) |visual_row, index| if (visual_row.owner.eql(wanted)) return index;
    // Width changes alter projected row starts. Restore a ReviewCard to the
    // same source offset's containing row, or the nearest following row. A
    // collapsed card's footer uses the body-end offset, so hidden content lands
    // on that disclosure instead of another item.
    var nearest: ?usize = null;
    var nearest_offset: usize = std.math.maxInt(usize);
    for (visual_rows, 0..) |visual_row, index| switch (wanted) {
        .comment => |value| if (visual_row.owner == .comment and visual_row.owner.comment.id == value.id and visual_row.owner.comment.part != .header and ((visual_row.owner.comment.source_offset <= value.source_offset and value.source_offset < visual_row.source_end) or visual_row.owner.comment.source_offset >= value.source_offset) and visual_row.owner.comment.source_offset < nearest_offset) {
            nearest = index;
            nearest_offset = visual_row.owner.comment.source_offset;
        },
        .draft => |value| if (visual_row.owner == .draft and visual_row.owner.draft.id == value.id and visual_row.owner.draft.part != .header and ((visual_row.owner.draft.source_offset <= value.source_offset and value.source_offset < visual_row.source_end) or visual_row.owner.draft.source_offset >= value.source_offset) and visual_row.owner.draft.source_offset < nearest_offset) {
            nearest = index;
            nearest_offset = visual_row.owner.draft.source_offset;
        },
        else => {},
    };
    if (nearest) |index| return index;
    return null;
}

fn visualRowAt(visual_rows: []const VisualRow, index: usize) ?VisualRow {
    if (index >= visual_rows.len) return null;
    return visual_rows[index];
}

fn owner(row: buffer_mod.Row) RowOwner {
    return switch (row) {
        .file_header => |file| .{ .file = file },
        .hunk_header => |hunk| .{ .hunk = hunk },
        .status_placeholder => |value| .{ .status_placeholder = .{ .file = value.file, .old = value.old != null, .new = value.new != null } },
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
        .line => |line| line.line.text.len,
        .line_pair => |pair| if (pair.right) |right| right.line.text.len else if (pair.left) |left| left.line.text.len else 0,
        .comment => |card| card.source_range.end,
        .draft => |card| card.source_range.end,
        else => 0,
    };
}

fn rowSourceStart(row: buffer_mod.Row) usize {
    return switch (row) {
        .comment => |card| card.source_range.start,
        .draft => |card| card.source_range.start,
        else => 0,
    };
}

fn rowDecoration(row: buffer_mod.Row) ?bbr.highlight.LineDecoration {
    return switch (row) {
        .line => |line| line.decoration,
        .line_pair => |pair| if (pair.right) |right| right.decoration else if (pair.left) |left| left.decoration else null,
        else => null,
    };
}

fn rowText(row: buffer_mod.Row) []const u8 {
    return switch (row) {
        .file_header => |file| file.displayPath(),
        .hunk_header => |hunk| hunk.header,
        .status_placeholder => "",
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

test "visual rows use the injected CellMetrics seam" {
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

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, metrics, .{ .layout = .unified, .width = 0, .wrap = false });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(@as(usize, 4), metrics_context.calls);
    try testing.expectEqual(@as(usize, 5), visual_rows[0].measured_cells);
}

test "Presentation Frame projects Diff Lines as complete visual rows" {
    const line: bbr.diff.Line = .{ .old_no = null, .new_no = 1, .kind = .added, .text = "const answer = 42" };
    const old_line: bbr.diff.Line = .{ .old_no = 1, .new_no = null, .kind = .removed, .text = "const answer = 41" };
    const runs = [_]bbr.highlight.decoration.Run{
        .{ .text = line.text[0..5], .capture = .{ .name = "keyword" } },
        .{ .text = line.text[5..], .emphasis = true },
    };
    const rows = [_]buffer_mod.Row{
        .{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } },
        .{ .line_pair = .{
            .left = .{ .line = &old_line, .decoration = .{ .runs = &.{.{ .text = old_line.text }} } },
            .right = .{ .line = &line, .decoration = .{ .runs = &runs } },
        } },
        .{ .section = .{ .kind = .pending, .count = 1 } },
    };

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, .bytes, .{ .layout = .unified, .width = 0, .wrap = false });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(rows.len, visual_rows.len);
    try testing.expect(visual_rows[0].owner.eql(.{ .line = &line }));
    try testing.expectEqual(@as(usize, 0), visual_rows[0].source_start);
    try testing.expectEqual(line.text.len, visual_rows[0].source_end);
    try testing.expectEqualStrings("const", visual_rows[0].decoration.?.runs[0].text);
    try testing.expectEqual(rows[0], visual_rows[0].row);
    try testing.expect(visual_rows[1].owner.eql(.{ .line = &line }));
    try testing.expectEqual(line.text.len, visual_rows[1].source_end);
    try testing.expectEqualStrings("const", visual_rows[1].decoration.?.runs[0].text);
    try testing.expectEqual(rows[1], visual_rows[1].row);
    try testing.expect(visual_rows[2].decoration == null);
    try testing.expectEqual(rows[2], visual_rows[2].row);
}

test "Diff visual-row allocation fails before a partial projection escapes" {
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "same" };
    const rows = [_]buffer_mod.Row{.{ .line = .{
        .line = &line,
        .decoration = .{ .runs = &.{.{ .text = line.text }} },
    } }};
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, buildVisualRowsWithOptions(failing.allocator(), &rows, .bytes, .{ .layout = .unified, .width = 0, .wrap = false }));
    try testing.expect(failing.has_induced_failure);
}

test "Unified visual rows prefer whitespace and preserve decoration slices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line: bbr.diff.Line = .{ .old_no = null, .new_no = 1, .kind = .added, .text = "alpha beta" };
    const runs = [_]bbr.highlight.decoration.Run{
        .{ .text = line.text[0..3], .capture = .{ .name = "keyword" } },
        .{ .text = line.text[3..8], .emphasis = true },
        .{ .text = line.text[8..] },
    };
    const rows = [_]buffer_mod.Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &runs } } }};

    const visual_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, .bytes, .{
        .layout = .unified,
        .width = 16,
        .wrap = true,
    });
    try testing.expectEqual(@as(usize, 2), visual_rows.len);
    try testing.expectEqual(@as(usize, 0), visual_rows[0].source_start);
    try testing.expectEqual(@as(usize, 6), visual_rows[0].source_end);
    try testing.expectEqual(@as(usize, 6), visual_rows[1].source_start);
    try testing.expectEqual(line.text.len, visual_rows[1].source_end);
    try testing.expect(!visual_rows[0].continuation);
    try testing.expect(visual_rows[1].continuation);
    try testing.expectEqualStrings("ha ", visual_rows[0].decoration.?.runs[1].text);
    try testing.expect(visual_rows[0].decoration.?.runs[1].emphasis);
    try testing.expectEqualStrings("be", visual_rows[1].decoration.?.runs[0].text);
    try testing.expect(visual_rows[1].decoration.?.runs[0].emphasis);
}

test "Unified hard wrapping keeps wide and combining graphemes complete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Metrics = struct {
        fn next(_: *const anyopaque, text: []const u8) @import("cell_metrics.zig").Measurement {
            if (std.mem.startsWith(u8, text, "e\xcc\x81")) return .{ .byte_len = 3, .cell_width = 1 };
            if (std.mem.startsWith(u8, text, "界")) return .{ .byte_len = 3, .cell_width = 2 };
            return .{ .byte_len = 1, .cell_width = 1 };
        }
    };
    const context: u8 = 0;
    const vtable: CellMetrics.VTable = .{ .next = Metrics.next };
    const metrics: CellMetrics = .{ .ptr = &context, .vtable = &vtable };
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "e\xcc\x81界" };
    const rows = [_]buffer_mod.Row{.{ .line = .{ .line = &line, .decoration = .{ .runs = &.{.{ .text = line.text }} } } }};

    const visual_rows = try buildVisualRowsWithOptions(arena.allocator(), &rows, metrics, .{
        .layout = .unified,
        .width = 12,
        .wrap = true,
    });
    try testing.expectEqual(@as(usize, 2), visual_rows.len);
    try testing.expectEqualStrings("e\xcc\x81", visual_rows[0].decoration.?.runs[0].text);
    try testing.expectEqualStrings("界", visual_rows[1].decoration.?.runs[0].text);
    try testing.expectEqual(@as(usize, 3), visual_rows[0].source_end);
    try testing.expectEqual(@as(usize, 6), visual_rows[1].source_end);
}

test "Unified wrapping keeps non-Line rows atomic when the body has no cells" {
    const file: bbr.diff.File = .{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = &.{} };
    const line: bbr.diff.Line = .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "long source" };
    const rows = [_]buffer_mod.Row{
        .{ .file_header = &file },
        .{ .status_placeholder = .{ .file = &file, .new = .{ .binary = 12 } } },
        .{ .disclosure = .{ .key = .{ .fold = &line }, .kind = .fold, .expanded = false, .count = 20 } },
        .{ .line = .{ .line = &line, .decoration = .{ .runs = &.{.{ .text = line.text }} } } },
    };

    const visual_rows = try buildVisualRowsWithOptions(testing.allocator, &rows, .bytes, .{
        .layout = .unified,
        .width = unified_gutter_cols,
        .wrap = true,
    });
    defer testing.allocator.free(visual_rows);

    try testing.expectEqual(rows.len, visual_rows.len);
    for (visual_rows, 0..) |visual_row, index| try testing.expectEqual(index, visual_row.buffer_index);
}

test "framed Pane geometry is bounded at zero narrow ordinary and wide sizes" {
    for ([_]Geometry{ .{ .cols = 0, .rows = 0 }, .{ .cols = 5, .rows = 2 }, .{ .cols = 80, .rows = 24 }, .{ .cols = 160, .rows = 40 } }) |geometry| {
        const panes = paneRects(geometry);
        try testing.expect(panes.sidebar.x + panes.sidebar.width <= geometry.cols);
        try testing.expect(panes.diff.x + panes.diff.width <= geometry.cols);
        try testing.expect(panes.sidebar_content.x + panes.sidebar_content.width <= geometry.cols);
        try testing.expect(panes.diff_content.y + panes.diff_content.height <= geometry.rows);
    }
    try testing.expectEqual(@as(u16, 1), paneRects(.{ .cols = 80, .rows = 24 }).diff.x - paneRects(.{ .cols = 80, .rows = 24 }).sidebar.width);
    try testing.expectEqual(@as(u16, 0), paneRects(.{ .cols = 40, .rows = 24 }).diff.x - paneRects(.{ .cols = 40, .rows = 24 }).sidebar.width);
}

test "Overlay geometry is centered and clipped to the published Frame" {
    try testing.expectEqual(Rect{ .x = 10, .y = 4, .width = 60, .height = 16 }, overlayRect(.{ .cols = 80, .rows = 24 }, 60, 16).?);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 20, .height = 8 }, overlayRect(.{ .cols = 20, .rows = 8 }, 60, 16).?);
    try testing.expect(overlayRect(.{ .cols = 0, .rows = 8 }, 60, 16) == null);
}

test "published Frame hit testing gives Overlay rows precedence and clips blank rows" {
    const entries = [_]file_tree.Entry{.{
        .identity = .{ .file = 0 },
        .parent = null,
        .depth = 0,
        .label = "a.zig",
    }};
    var projection: Projection = .{
        .revision = 7,
        .visual_rows_revision = 7,
        .geometry = .{ .cols = 20, .rows = 8 },
        .panes = paneRects(.{ .cols = 20, .rows = 8 }),
        .visual_rows = &.{},
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = Nav.init(0, 5),
        .file_tree = .{ .entries = &entries, .viewport = 5 },
        .overlay = .{ .kind = .picker, .rect = .{ .x = 5, .y = 1, .width = 10, .height = 4 }, .row_count = 2 },
    };

    try testing.expectEqual(HitTarget{ .picker_entry = 0 }, hitTest(projection, 6, 2).?);
    try testing.expectEqual(HitTarget{ .picker_entry = 1 }, hitTest(projection, 6, 3).?);
    try testing.expect(hitTest(projection, 6, 4) == null);
    try testing.expect(hitTest(projection, 1, 2) == null); // Overlay capture prevents Pane pass-through.

    projection.overlay = null;
    try testing.expectEqual(HitTarget{ .sidebar_entry = 0 }, hitTest(projection, 1, 2).?);
    try testing.expectEqual(HitTarget.sidebar, hitTest(projection, 1, 3).?);
    try testing.expect(hitTest(projection, 0, 2) == null); // Pane border.
}

test "navigation restoration follows stable owners and clears a shifted Selection" {
    const old_targets = [_]VisualRow{
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .section = .{ .kind = .pr_comments, .path = "" } }, .measured_cells = 0 },
        .{ .row = .{ .section = .{ .kind = .outdated, .count = 1, .path = "a.zig" } }, .owner = .{ .section = .{ .kind = .outdated, .path = "a.zig" } }, .measured_cells = 5 },
    };
    const new_targets = [_]VisualRow{
        .{ .row = .{ .section = .{ .kind = .pending, .count = 1 } }, .owner = .{ .section = .{ .kind = .pending, .path = "" } }, .measured_cells = 0 },
        old_targets[0],
        old_targets[1],
    };
    var navigation = Nav.init(old_targets.len, 4);
    navigation.cursor = 1;
    navigation.mark = 0;
    navigation.count = 7;
    const previous: Projection = .{
        .revision = 4,
        .visual_rows_revision = 4,
        .geometry = .{ .cols = 80, .rows = 4 },
        .panes = paneRects(.{ .cols = 80, .rows = 4 }),
        .visual_rows = &old_targets,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = navigation,
    };

    const restored = restoreNavigation(previous, &new_targets, .{ .cols = 60, .rows = 3 });

    try testing.expectEqual(@as(usize, 2), restored.cursor);
    try testing.expectEqual(@as(usize, 7), restored.count);
    try testing.expectEqual(@as(usize, 1), restored.viewport);
    try testing.expect(restored.mark == null);
}

test "ReviewCard restoration follows containing source offset and collapsed footer" {
    const old_targets = [_]VisualRow{
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } }, .measured_cells = 5 },
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .comment = .{ .id = 7, .source_offset = 8 } }, .measured_cells = 10, .source_end = 18 },
    };
    var navigation = Nav.init(old_targets.len, 3);
    navigation.cursor = 1;
    const previous: Projection = .{
        .revision = 1,
        .visual_rows_revision = 1,
        .geometry = .{ .cols = 40, .rows = 3 },
        .panes = paneRects(.{ .cols = 40, .rows = 3 }),
        .visual_rows = &old_targets,
        .buffer = .{ .rows = &.{}, .layout = .unified },
        .navigation = navigation,
    };
    const resized = [_]VisualRow{
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .comment = .{ .id = 7, .source_offset = 0, .part = .header } }, .measured_cells = 5 },
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .comment = .{ .id = 7, .source_offset = 4 } }, .measured_cells = 18, .source_end = 14 },
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .comment = .{ .id = 7, .source_offset = 14 } }, .measured_cells = 4, .source_end = 18 },
    };
    try testing.expectEqual(@as(usize, 1), restoreNavigation(previous, &resized, .{ .cols = 60, .rows = 3 }).cursor);

    const collapsed = [_]VisualRow{
        resized[0],
        .{ .row = .{ .section = .{ .kind = .pr_comments, .count = 1 } }, .owner = .{ .comment = .{ .id = 7, .source_offset = 18, .part = .disclosure_footer } }, .measured_cells = 20, .source_end = 18 },
    };
    try testing.expectEqual(@as(usize, 1), restoreNavigation(previous, &collapsed, .{ .cols = 30, .rows = 3 }).cursor);
}
