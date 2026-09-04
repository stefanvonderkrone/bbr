const std = @import("std");
const bbr = @import("bbr");
const buffer_mod = @import("benchmark_buffer");

pub const Context = struct {
    diff: bbr.diff.Diff,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !buffer_mod.Buffer {
    return buffer_mod.build(allocator, context.diff, .side_by_side);
}

pub fn checksum(buffer: buffer_mod.Buffer) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (buffer.rows) |row| {
        hash.update(&.{@intFromEnum(row)});
        if (row == .line_pair) {
            if (row.line_pair.left) |line| hash.update(line.line.text);
            if (row.line_pair.right) |line| hash.update(line.line.text);
        }
    }
    return hash.final();
}
