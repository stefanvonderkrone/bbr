//! Buffer — the flattened, ordered rows the renderer walks to draw one `Diff`.
//!
//! A `Diff` is a tree (files → hunks → lines); rendering and navigation want a
//! flat sequence. `build` flattens the tree into `Row`s for a given `Layout`.
//! Zero-copy: every `Row` points into the `Diff` it was built from, so the
//! `Diff` (and the raw text it borrows) must outlive the `Buffer`. Only the row
//! array is allocated — pass an arena.
//!
//! Presentation concern, but it depends only on the diff model (no vaxis), so it
//! lives with the model and stays hermetically testable.

const std = @import("std");
const model = @import("model.zig");

/// How a `Buffer` is arranged on screen. Only `unified` is built today;
/// `side_by_side` is the other axis (design §11) and lands later.
pub const Layout = enum { unified, side_by_side };

pub const RowKind = enum { file_header, hunk_header, line };

/// One drawable row. Borrows the diff node it projects.
pub const Row = union(RowKind) {
    file_header: *const model.File,
    hunk_header: *const model.Hunk,
    line: *const model.Line,
};

pub const Buffer = struct {
    rows: []const Row,
    layout: Layout,
};

pub const BuildError = error{
    /// The requested `Layout` is not implemented yet.
    LayoutUnsupported,
} || std.mem.Allocator.Error;

/// Flatten `diff` into rows for `layout`. `allocator` should be the
/// buffer-scoped arena; the returned rows borrow `diff`.
pub fn build(allocator: std.mem.Allocator, diff: model.Diff, layout: Layout) BuildError!Buffer {
    if (layout != .unified) return BuildError.LayoutUnsupported;

    var rows: std.ArrayList(Row) = .empty;
    for (diff.files) |*file| {
        try rows.append(allocator, .{ .file_header = file });
        for (file.hunks) |*hunk| {
            try rows.append(allocator, .{ .hunk_header = hunk });
            for (hunk.lines) |*ln| {
                try rows.append(allocator, .{ .line = ln });
            }
        }
    }
    return .{ .rows = try rows.toOwnedSlice(allocator), .layout = layout };
}

// ---------------------------------------------------------------------------
// Tests — hermetic; build a Diff via the parser, then flatten it.
// ---------------------------------------------------------------------------

const testing = std.testing;
const parse = @import("parser.zig").parse;

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

test "build flattens files → hunks → lines in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, two_file_diff);
    const buf = try build(a, diff, .unified);

    try testing.expectEqual(Layout.unified, buf.layout);
    // file A: header + hunk header + 3 lines = 5; file B: header + hunk + 2 = 4.
    try testing.expectEqual(@as(usize, 9), buf.rows.len);

    try testing.expect(buf.rows[0] == .file_header);
    try testing.expectEqualStrings("a.txt", buf.rows[0].file_header.new_path);
    try testing.expect(buf.rows[1] == .hunk_header);
    try testing.expect(buf.rows[2] == .line);
    try testing.expectEqual(model.LineKind.context, buf.rows[2].line.kind);
    try testing.expectEqual(model.LineKind.removed, buf.rows[3].line.kind);
    try testing.expectEqual(model.LineKind.added, buf.rows[4].line.kind);

    try testing.expect(buf.rows[5] == .file_header);
    try testing.expectEqualStrings("b.txt", buf.rows[5].file_header.new_path);
    try testing.expect(buf.rows[6] == .hunk_header);
    try testing.expectEqual(model.LineKind.context, buf.rows[7].line.kind);
    try testing.expectEqual(model.LineKind.added, buf.rows[8].line.kind);
}

test "rows borrow the diff (pointer identity, not copies)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try parse(a, two_file_diff);
    const buf = try build(a, diff, .unified);

    try testing.expectEqual(&diff.files[0], buf.rows[0].file_header);
    try testing.expectEqual(&diff.files[0].hunks[0].lines[0], buf.rows[2].line);
}

test "empty diff yields no rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = try build(a, .{ .files = &.{} }, .unified);
    try testing.expectEqual(@as(usize, 0), buf.rows.len);
}

test "side_by_side is not yet supported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(BuildError.LayoutUnsupported, build(arena.allocator(), .{ .files = &.{} }, .side_by_side));
}
