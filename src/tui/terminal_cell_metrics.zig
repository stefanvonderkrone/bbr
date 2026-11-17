//! The vaxis cell measurement that the terminal paints with. The app and the
//! benchmarks share this one adapter, so a benchmark measures the same
//! grapheme work as a Buffer rebuild.

const std = @import("std");
const vaxis = @import("vaxis");
const cell_metrics = @import("cell_metrics.zig");

pub const metrics: cell_metrics.CellMetrics = .{ .ptr = &context, .vtable = &vtable };
const context: u8 = 0;
const vtable: cell_metrics.CellMetrics.VTable = .{ .next = nextGrapheme, .width = widthText };

fn nextGrapheme(_: *const anyopaque, text: []const u8) cell_metrics.Measurement {
    var iterator = vaxis.unicode.graphemeIterator(text);
    const grapheme = iterator.next() orelse return .{ .byte_len = 1, .cell_width = 1 };
    return .{ .byte_len = grapheme.len, .cell_width = vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode) };
}

fn widthText(_: *const anyopaque, text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}

test "vaxis measures each printable ASCII byte before ASCII or the end as one grapheme of one cell" {
    try std.testing.expect(metrics.ascii_is_narrow);
    for (0x20..0x7f) |first| {
        const alone = [_]u8{@intCast(first)};
        try std.testing.expectEqual(cell_metrics.Measurement{ .byte_len = 1, .cell_width = 1 }, nextGrapheme(&context, &alone));
        for (0..0x80) |second| {
            const pair = [_]u8{ @intCast(first), @intCast(second) };
            try std.testing.expectEqual(cell_metrics.Measurement{ .byte_len = 1, .cell_width = 1 }, nextGrapheme(&context, &pair));
        }
    }
}
