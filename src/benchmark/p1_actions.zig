const std = @import("std");
const bbr = @import("bbr");
const tui = @import("benchmark_tui");

pub const line_size = @sizeOf(bbr.diff.Line);
pub const span_size = @sizeOf(bbr.highlight.Span);
pub const row_size = @sizeOf(tui.buffer.Row);
pub const visual_row_size = @sizeOf(tui.frame.VisualRow);

pub const ReviewBodiesContext = struct {
    body: []const u8,
    count: usize,
};

pub fn reviewBodies(allocator: std.mem.Allocator, context: *const ReviewBodiesContext) !u64 {
    var hash = std.hash.Wyhash.init(0);
    for (0..context.count) |_| {
        const body = try tui.review_body.ReviewBody.parse(allocator, context.body);
        hash.update(std.mem.asBytes(&body.blocks.len));
        for (body.blocks) |block| hash.update(std.mem.asBytes(&block.source));
    }
    return hash.final();
}

pub fn scalarChecksum(value: u64) u64 {
    return value;
}

pub const WholeFileContext = struct {
    diff: bbr.diff.Diff,
    blobs: []const bbr.diff.FileBlob,
};

pub fn wholeFile(allocator: std.mem.Allocator, context: *const WholeFileContext) !tui.buffer.Buffer {
    return tui.buffer.buildWithComments(allocator, context.diff, .unified, &.{}, .{
        .whole_file = true,
        .blobs = context.blobs,
    });
}

pub fn bufferChecksum(buffer: tui.buffer.Buffer) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (buffer.rows) |row| {
        hash.update(&.{@intFromEnum(row)});
        switch (row) {
            .line => |line| hash.update(line.line.text),
            else => {},
        }
    }
    return hash.final();
}

pub const VisualRowsContext = struct {
    rows: []const tui.buffer.Row,
    wrap: bool,
    width: usize = 120,
};

pub fn visualRows(allocator: std.mem.Allocator, context: *const VisualRowsContext) ![]const tui.frame.VisualRow {
    return tui.frame.buildVisualRowsWithOptions(allocator, context.rows, .bytes, .{
        .layout = .unified,
        .width = context.width,
        .wrap = context.wrap,
    });
}

pub fn visualRowsChecksum(rows: []const tui.frame.VisualRow) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (rows) |row| {
        hash.update(&.{@intFromEnum(row.kind)});
        hash.update(std.mem.asBytes(&row.buffer_index));
        hash.update(std.mem.asBytes(&row.source_start));
        hash.update(std.mem.asBytes(&row.source_end));
    }
    return hash.final();
}

pub const FileTreeContext = struct {
    diff: bbr.diff.Diff,
    tallies: []const tui.buffer.FileTally,
};

pub fn fileTree(allocator: std.mem.Allocator, context: *const FileTreeContext) !tui.file_tree.Projection {
    return tui.file_tree.build(
        allocator,
        context.diff,
        context.tallies,
        &.{},
        null,
        40,
        50,
        null,
        0,
        .bytes,
    );
}

pub fn fileTreeChecksum(projection: tui.file_tree.Projection) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (projection.entries) |entry| {
        hash.update(entry.label);
        hash.update(std.mem.asBytes(&entry.comments));
        hash.update(std.mem.asBytes(&entry.drafts));
    }
    return hash.final();
}
