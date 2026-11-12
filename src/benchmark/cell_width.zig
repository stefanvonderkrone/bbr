const std = @import("std");
const tui = @import("benchmark_tui");

pub const name = "cell_width_ascii_1m";

pub fn run(_: std.mem.Allocator, text: []const u8) !usize {
    return tui.terminal_cell_metrics.width(text);
}

pub fn checksum(width: usize) u64 {
    return width;
}
