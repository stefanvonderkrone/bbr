const std = @import("std");
const bbr = @import("bbr");
const buffer_mod = @import("benchmark_buffer");

pub const Context = struct {
    diff: bbr.diff.Diff,
    highlights: []const bbr.highlight.FileHighlights,
    layout: buffer_mod.Layout,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !buffer_mod.Buffer {
    return buffer_mod.buildWithComments(allocator, context.diff, context.layout, &.{}, .{ .highlights = context.highlights });
}

pub fn checksum(buffer: buffer_mod.Buffer) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (buffer.rows) |row| switch (row) {
        .line => |line| hashLine(&hash, line),
        .line_pair => |pair| {
            if (pair.left) |line| hashLine(&hash, line);
            if (pair.right) |line| hashLine(&hash, line);
        },
        else => {},
    };
    return hash.final();
}

fn hashLine(hash: *std.hash.Wyhash, line: buffer_mod.LineRow) void {
    hash.update(line.line.text);
    for (line.decoration.runs) |decoration_run| {
        hash.update(decoration_run.text);
        if (decoration_run.capture) |capture| {
            hash.update(std.mem.asBytes(&capture.id));
            hash.update(&.{@intFromEnum(capture.role)});
        }
    }
}
