const std = @import("std");
const buffer_mod = @import("benchmark_buffer");

pub const name = "buffer_navigation_300_files_50000_lines";

pub const Context = struct {
    buffer: buffer_mod.Buffer,
};

pub fn run(_: std.mem.Allocator, context: *const Context) !u64 {
    var total: u64 = 0;
    for (0..1_000) |_| total +%= context.buffer.fileIndexForRow(context.buffer.rows.len - 1).?;
    return total;
}

pub fn checksum(value: u64) u64 {
    return value;
}
