const std = @import("std");
const vaxis = @import("vaxis");
const CellMetrics = @import("benchmark_buffer").CellMetrics;

pub const name = "cell_width_ascii_1m";

const context: u8 = 0;
const vtable: CellMetrics.VTable = .{ .next = nextVaxisGrapheme, .width = widthVaxisText };
const metrics: CellMetrics = .{ .ptr = &context, .vtable = &vtable };

pub fn run(_: std.mem.Allocator, text: []const u8) !usize {
    return metrics.width(text);
}

pub fn checksum(width: usize) u64 {
    return width;
}

fn nextVaxisGrapheme(_: *const anyopaque, text: []const u8) @import("benchmark_buffer").CellMeasurement {
    var iterator = vaxis.unicode.graphemeIterator(text);
    const grapheme = iterator.next() orelse return .{ .byte_len = 1, .cell_width = 1 };
    return .{
        .byte_len = grapheme.len,
        .cell_width = vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode),
    };
}

fn widthVaxisText(_: *const anyopaque, text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}
