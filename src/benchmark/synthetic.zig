const std = @import("std");

pub fn largeDiff(allocator: std.mem.Allocator) ![]u8 {
    const file_count = 300;
    const line_count = 50_000;
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);

    var emitted: usize = 0;
    for (0..file_count) |file_index| {
        const remaining = line_count - emitted;
        const files_left = file_count - file_index;
        const lines = remaining / files_left;
        try raw.print(
            allocator,
            "diff --git a/src/file_{d}.zig b/src/file_{d}.zig\n--- a/src/file_{d}.zig\n+++ b/src/file_{d}.zig\n@@ -1,{d} +1,{d} @@\n",
            .{ file_index, file_index, file_index, file_index, lines, lines },
        );
        for (0..lines) |line_index| {
            try raw.print(allocator, " const value_{d} = {d};\n", .{ line_index, line_index });
        }
        emitted += lines;
    }
    return raw.toOwnedSlice(allocator);
}

pub const LinePair = struct {
    old: []u8,
    new: []u8,

    pub fn deinit(self: LinePair, allocator: std.mem.Allocator) void {
        allocator.free(self.old);
        allocator.free(self.new);
    }
};

pub fn minifiedLinePair(allocator: std.mem.Allocator, part_count: usize) !LinePair {
    var old: std.ArrayList(u8) = .empty;
    errdefer old.deinit(allocator);
    var new: std.ArrayList(u8) = .empty;
    errdefer new.deinit(allocator);
    for (0..part_count) |i| {
        try old.print(allocator, "v{d}+", .{i});
        try new.print(allocator, "v{d}{s}+", .{ i, if (i % 17 == 0) "x" else "" });
    }
    return .{
        .old = try old.toOwnedSlice(allocator),
        .new = try new.toOwnedSlice(allocator),
    };
}
