//! The Scroll Marks of the DiffPane scroll bar. Each visual row build computes
//! the row marks once, and paint projects them onto the track cells with the
//! same `view.trackCell` as the thumb.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer_mod = @import("buffer.zig");
const frame = @import("frame.zig");
const view = @import("view.zig");

pub const RowMark = struct {
    kind: view.ScrollMark,
    /// The first visual row.
    first: usize,
    /// The visual row after the last one.
    end: usize,
};

/// The row marks of `visual_rows`, sorted by `first`. A Thread mark covers
/// the root ReviewCard and all its Replies. A Draft mark covers only its own
/// ReviewCard, so it can sit inside a Thread mark.
pub fn rowMarks(allocator: Allocator, buffer: buffer_mod.Buffer, visual_rows: []const frame.VisualRow) ![]const RowMark {
    var marks: std.ArrayList(RowMark) = .empty;
    errdefer marks.deinit(allocator);
    const Open = struct { mark: usize, buffer_end: usize };
    var thread: ?Open = null;
    var draft: ?Open = null;
    for (visual_rows, 0..) |visual, index| {
        const buffer_index = visual.buffer_index;
        inline for (.{ &thread, &draft }) |open| if (open.*) |value| if (buffer_index >= value.buffer_end) {
            marks.items[value.mark].end = index;
            open.* = null;
        };
        if (index > 0 and visual_rows[index - 1].buffer_index == buffer_index) continue;
        switch (buffer.rows[buffer_index]) {
            .file_header => try marks.append(allocator, .{ .kind = .file_header, .first = index, .end = index + 1 }),
            .disclosure => |disclosure| if (disclosure.kind == .resolved_thread)
                try marks.append(allocator, .{ .kind = .resolved_thread, .first = index, .end = index + 1 }),
            .comment => |card| if (card.part == .header and card.depth == 0) {
                thread = .{ .mark = marks.items.len, .buffer_end = card.card.?.subtree_end };
                try marks.append(allocator, .{ .kind = if (card.resolved_thread) .resolved_thread else .unresolved_thread, .first = index, .end = visual_rows.len });
            },
            .draft => |card| if (card.part == .header) {
                draft = .{ .mark = marks.items.len, .buffer_end = card.card.?.rows.end };
                try marks.append(allocator, .{ .kind = .draft, .first = index, .end = visual_rows.len });
            },
            else => {},
        }
    }
    return marks.toOwnedSlice(allocator);
}

/// One entry per track cell, or none when every row fits. A cell shows its
/// highest priority Scroll Mark, and a Buffer Search hit outranks every row
/// mark. The hits must be sorted by visual row.
pub fn project(
    allocator: Allocator,
    extent: u16,
    total: usize,
    row_marks: []const RowMark,
    hits: []const frame.ProjectedSourceRange,
) Allocator.Error![]const ?view.ScrollMark {
    if (extent == 0 or total <= extent) return &.{};
    const cells = try allocator.alloc(?view.ScrollMark, extent);
    @memset(cells, null);
    for (row_marks) |mark| {
        const end = @min(mark.end, total);
        if (mark.first >= end) continue;
        for (cells[view.trackCell(extent, total, mark.first) .. view.trackCell(extent, total, end - 1) + 1]) |*cell| {
            if (cell.* == null or mark.kind.outranks(cell.*.?)) cell.* = mark.kind;
        }
    }
    for (cells, 0..) |*cell, index| {
        const first = view.cellFirstRow(extent, total, @intCast(index));
        const end = if (index + 1 == extent) total else view.cellFirstRow(extent, total, @intCast(index + 1));
        const hit = std.sort.partitionPoint(frame.ProjectedSourceRange, hits, first, rowBefore);
        if (hit < hits.len and hits[hit].visual_row < end) cell.* = .buffer_search_hit;
    }
    return cells;
}

fn rowBefore(row: usize, hit: frame.ProjectedSourceRange) bool {
    return hit.visual_row < row;
}

const testing = std.testing;
const bbr = @import("bbr");
const Comment = bbr.review.Comment;
const Draft = bbr.review.Draft;

const two_file_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-old
    \\+new
    \\diff --git a/b.txt b/b.txt
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -5 +5,2 @@
    \\ ctx
    \\+extra
    \\
;

const Built = struct {
    buffer: buffer_mod.Buffer,
    visual_rows: []const frame.VisualRow,
    marks: []const RowMark,

    fn kindAt(self: Built, index: usize) buffer_mod.RowKind {
        return std.meta.activeTag(self.buffer.rows[self.visual_rows[index].buffer_index]);
    }

    fn count(self: Built, kind: view.ScrollMark) usize {
        var n: usize = 0;
        for (self.marks) |mark| n += @intFromBool(mark.kind == kind);
        return n;
    }

    fn only(self: Built, kind: view.ScrollMark) !RowMark {
        try testing.expectEqual(@as(usize, 1), self.count(kind));
        for (self.marks) |mark| if (mark.kind == kind) return mark;
        unreachable;
    }

    /// The rows from the first to the last row of `kinds`.
    fn span(self: Built, kinds: []const buffer_mod.RowKind) RowMark {
        var first: ?usize = null;
        var end: usize = 0;
        for (0..self.visual_rows.len) |index| if (std.mem.indexOfScalar(buffer_mod.RowKind, kinds, self.kindAt(index)) != null) {
            if (first == null) first = index;
            end = index + 1;
        };
        return .{ .kind = .file_header, .first = first.?, .end = end };
    }
};

fn build(a: Allocator, comments: []const Comment, options: buffer_mod.BuildOptions) !Built {
    const diff = try bbr.diff.parse(a, two_file_diff);
    const threads = try bbr.review.thread.build(a, comments);
    var opts = options;
    opts.scratch_allocator = a;
    const buffer = try buffer_mod.buildWithComments(a, diff, .unified, threads, opts);
    const visual_rows = try frame.buildVisualRowsWithOptions(a, buffer.rows, .bytes, .{ .layout = .unified, .width = 80 });
    const marks = try rowMarks(a, buffer, visual_rows);
    for (marks[1..], marks[0 .. marks.len - 1]) |mark, previous| try testing.expect(previous.first <= mark.first);
    return .{ .buffer = buffer, .visual_rows = visual_rows, .marks = marks };
}

fn expectRange(expected: RowMark, actual: RowMark) !void {
    try testing.expectEqual(expected.first, actual.first);
    try testing.expectEqual(expected.end, actual.end);
}

test "M30 scrollbar rowMarks marks a Thread over its Replies and a Draft Reply over its own card" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "open", .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "reply" },
    };
    const drafts = [_]Draft{.{ .local_id = 1, .kind = .comment, .body = "my reply", .parent = .{ .comment = 2 } }};
    const built = try build(a, &comments, .{ .drafts = &drafts });

    try expectRange(built.span(&.{ .comment, .draft }), try built.only(.unresolved_thread));
    try expectRange(built.span(&.{.draft}), try built.only(.draft));
    try testing.expect(built.kindAt(built.span(&.{.draft}).first - 1) == .comment);
    try testing.expectEqual(@as(usize, 0), built.count(.resolved_thread));
}

test "M30 scrollbar rowMarks gives a File header mark on each File header row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const built = try build(a, &.{}, .{});
    try testing.expectEqual(@as(usize, 2), built.marks.len);
    for (built.marks) |mark| {
        try testing.expectEqual(view.ScrollMark.file_header, mark.kind);
        try testing.expectEqual(mark.first + 1, mark.end);
        try testing.expectEqual(buffer_mod.RowKind.file_header, built.kindAt(mark.first));
    }
}

test "M30 scrollbar rowMarks gives a Draft root a Draft mark and no Thread mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const drafts = [_]Draft{.{ .local_id = 1, .kind = .comment, .body = "root", .anchor = .{ .path = "a.txt", .to = 2, .commit = "c0" } }};
    const built = try build(a, &.{}, .{ .drafts = &drafts });
    try expectRange(built.span(&.{.draft}), try built.only(.draft));
    try testing.expectEqual(@as(usize, 0), built.count(.unresolved_thread) + built.count(.resolved_thread));
}

test "M30 scrollbar rowMarks marks an expanded resolved Thread over its Replies and a collapsed one on its disclosure row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "nit", .resolved = true, .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "fixed" },
    };
    const expanded = try build(a, &comments, .{ .expanded_disclosures = &.{.{ .resolved_thread = 1 }} });
    try expectRange(expanded.span(&.{.comment}), try expanded.only(.resolved_thread));
    try testing.expect(expanded.span(&.{.comment}).end - expanded.span(&.{.comment}).first > 2);

    const collapsed = try build(a, &comments, .{});
    const mark = try collapsed.only(.resolved_thread);
    try testing.expectEqual(mark.first + 1, mark.end);
    try testing.expectEqual(buffer_mod.RowKind.disclosure, collapsed.kindAt(mark.first));
    try testing.expectEqual(@as(usize, 0), collapsed.count(.unresolved_thread));
}

test "M30 scrollbar rowMarks gives a Deleted Comment root an unresolved Thread mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "", .deleted = true, .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .parent_id = 1, .author = "Bo", .body = "survives" },
    };
    const built = try build(a, &comments, .{});
    try expectRange(built.span(&.{.comment}), try built.only(.unresolved_thread));
}

test "M30 scrollbar rowMarks gives a hidden Thread and a closed Outdated section no mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{
        .{ .id = 1, .author = "Ada", .body = "on a", .anchor = .{ .path = "a.txt", .to = 2 } },
        .{ .id = 2, .author = "Bo", .body = "stale", .state = .outdated, .anchor = .{ .path = "b.txt", .from = 99 } },
    };
    const whole = try build(a, &comments, .{});
    try testing.expectEqual(@as(usize, 1), whole.count(.unresolved_thread));
    try testing.expect(whole.span(&.{.disclosure}).end > 0);

    const isolated = try build(a, &comments, .{ .only_file = 1 });
    try testing.expectEqual(@as(usize, 0), isolated.count(.unresolved_thread));
    try testing.expectEqual(@as(usize, 1), isolated.marks.len);
}

test "M30 scrollbar rowMarks keeps the mark of a ReviewCard with a collapsed body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comments = [_]Comment{.{ .id = 1, .author = "Ada", .body = "one\n\ntwo\n\nthree\n\nfour", .anchor = .{ .path = "a.txt", .to = 2 } }};
    const built = try build(a, &comments, .{ .collapsed_rows = 1 });
    var collapsed = false;
    for (built.visual_rows) |visual| switch (built.buffer.rows[visual.buffer_index]) {
        .comment => |card| collapsed = collapsed or card.hidden_rows > 0,
        else => {},
    };
    try testing.expect(collapsed);
    try expectRange(built.span(&.{.comment}), try built.only(.unresolved_thread));
}

test "M30 scrollbar the mark projection puts each row range on its track cells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marks = [_]RowMark{
        .{ .kind = .file_header, .first = 0, .end = 1 },
        .{ .kind = .unresolved_thread, .first = 25, .end = 47 },
        .{ .kind = .resolved_thread, .first = 99, .end = 100 },
        .{ .kind = .draft, .first = 100, .end = 140 },
    };
    const cells = try project(a, 10, 100, &marks, &.{});
    const expected = [_]?view.ScrollMark{ .file_header, null, .unresolved_thread, .unresolved_thread, .unresolved_thread, null, null, null, null, .resolved_thread };
    try testing.expectEqualSlices(?view.ScrollMark, &expected, cells);

    for (1..30) |extent| for (extent + 1..90) |total| for (0..total) |first| {
        const end = @min(total, first + 1 + first % 7);
        const one = [_]RowMark{.{ .kind = .draft, .first = first, .end = end }};
        const projected = try project(a, @intCast(extent), total, &one, &.{});
        try testing.expectEqual(extent, projected.len);
        for (projected, 0..) |cell, index| {
            const cell_first = view.cellFirstRow(@intCast(extent), total, @intCast(index));
            const cell_end = if (index + 1 == extent) total else view.cellFirstRow(@intCast(extent), total, @intCast(index + 1));
            try testing.expectEqual(cell_first < end and first < cell_end, cell != null);
        }
    };
}

test "M30 scrollbar a cell shows the highest priority Scroll Mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (std.meta.tags(view.ScrollMark)) |high| for (std.meta.tags(view.ScrollMark)) |low| {
        if (!high.outranks(low)) continue;
        for ([_][2]view.ScrollMark{ .{ high, low }, .{ low, high } }) |order| {
            const marks = [_]RowMark{ .{ .kind = order[0], .first = 40, .end = 41 }, .{ .kind = order[1], .first = 44, .end = 49 } };
            const cells = try project(a, 10, 100, &marks, &.{});
            try testing.expectEqual(@as(?view.ScrollMark, high), cells[4]);
        }
    };
    const hit: frame.ProjectedSourceRange = .{ .visual_row = 45, .relation = .neutral, .source = .{ .start = 0, .end = 1 }, .row = .{ .start = 0, .end = 1 }, .active = false };
    for (std.meta.tags(view.ScrollMark)) |kind| {
        const marks = [_]RowMark{.{ .kind = kind, .first = 40, .end = 50 }};
        const cells = try project(a, 10, 100, &marks, &.{hit});
        try testing.expectEqual(@as(?view.ScrollMark, .buffer_search_hit), cells[4]);
    }
}

test "M30 scrollbar the projection gives no cell when every row fits and ignores marks past the total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marks = [_]RowMark{.{ .kind = .draft, .first = 0, .end = 5 }};
    try testing.expectEqual(@as(usize, 0), (try project(a, 10, 10, &marks, &.{})).len);
    try testing.expectEqual(@as(usize, 0), (try project(a, 0, 10, &marks, &.{})).len);
    const past = [_]RowMark{.{ .kind = .draft, .first = 30, .end = 40 }};
    for (try project(a, 10, 20, &past, &.{})) |cell| try testing.expectEqual(@as(?view.ScrollMark, null), cell);
}

test "M30 scrollbar the binary search and a linear scan give the same hit cells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(30);
    const random = prng.random();
    for (0..200) |_| {
        const total = random.intRangeAtMost(usize, 2, 300);
        const extent: u16 = @intCast(random.intRangeLessThan(usize, 1, total));
        const hits = try a.alloc(frame.ProjectedSourceRange, random.uintLessThan(usize, 20));
        for (hits) |*hit| hit.* = .{ .visual_row = random.uintLessThan(usize, total + 5), .relation = .neutral, .source = .{ .start = 0, .end = 1 }, .row = .{ .start = 0, .end = 1 }, .active = false };
        std.mem.sort(frame.ProjectedSourceRange, hits, {}, struct {
            fn lessThan(_: void, lhs: frame.ProjectedSourceRange, rhs: frame.ProjectedSourceRange) bool {
                return lhs.visual_row < rhs.visual_row;
            }
        }.lessThan);
        const linear = try a.alloc(?view.ScrollMark, extent);
        @memset(linear, null);
        for (hits) |hit| if (hit.visual_row < total) {
            linear[view.trackCell(extent, total, hit.visual_row)] = .buffer_search_hit;
        };
        try testing.expectEqualSlices(?view.ScrollMark, linear, try project(a, extent, total, &.{}, hits));
    }
}

test "M30 scrollbar the projection ignores a hit at or past the total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hits: [3]frame.ProjectedSourceRange = undefined;
    for (&hits, [_]usize{ 19, 20, 23 }) |*hit, row| hit.* = .{ .visual_row = row, .relation = .neutral, .source = .{ .start = 0, .end = 1 }, .row = .{ .start = 0, .end = 1 }, .active = false };
    var expected = [_]?view.ScrollMark{null} ** 10;
    expected[9] = .buffer_search_hit;
    try testing.expectEqualSlices(?view.ScrollMark, &expected, try project(a, 10, 20, &.{}, &hits));
    for (try project(a, 10, 20, &.{}, hits[1..])) |cell| try testing.expectEqual(@as(?view.ScrollMark, null), cell);
}
