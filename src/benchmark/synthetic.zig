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
        if (i % 2 == 0) {
            try old.print(allocator, "v{d}", .{i});
            try new.print(allocator, "v{d}{s}", .{ i, if (i % 34 == 0) "x" else "" });
        } else {
            try old.append(allocator, '+');
            try new.append(allocator, '+');
        }
    }
    return .{
        .old = try old.toOwnedSlice(allocator),
        .new = try new.toOwnedSlice(allocator),
    };
}

pub fn replacementBlock(allocator: std.mem.Allocator, line_count: usize) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);
    try raw.print(
        allocator,
        "diff --git a/src/replacement.zig b/src/replacement.zig\n--- a/src/replacement.zig\n+++ b/src/replacement.zig\n@@ -1,{d} +1,{d} @@\n",
        .{ line_count, line_count },
    );
    for (0..line_count) |i| try raw.print(allocator, "-const value_{d} = source_{d};\n", .{ i, i });
    for (0..line_count) |i| try raw.print(allocator, "+const value_{d} = target_{d};\n", .{ i, i });
    return raw.toOwnedSlice(allocator);
}
