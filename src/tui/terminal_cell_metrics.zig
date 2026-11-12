//! The vaxis cell measurement that the terminal paints with. The app and the
//! benchmarks share this one adapter, so a benchmark measures the same
//! grapheme work as a Buffer rebuild.

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
