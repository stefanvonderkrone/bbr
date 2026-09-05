//! Terminal-cell measurement seam used by every width-dependent projection.

const std = @import("std");

pub const Measurement = struct {
    byte_len: usize,
    cell_width: usize,
};

pub const CellMetrics = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *const anyopaque, text: []const u8) Measurement,
        width: ?*const fn (ptr: *const anyopaque, text: []const u8) usize = null,
    };

    pub fn next(self: CellMetrics, text: []const u8) Measurement {
        if (text.len == 0) return .{ .byte_len = 0, .cell_width = 0 };
        const measured = self.vtable.next(self.ptr, text);
        // A faulty adapter must not make projection loop forever or step beyond
        // the source it was asked to measure.
        return .{
            .byte_len = if (measured.byte_len == 0 or measured.byte_len > text.len) 1 else measured.byte_len,
            .cell_width = measured.cell_width,
        };
    }

    pub fn width(self: CellMetrics, text: []const u8) usize {
        if (isNarrowAscii(text)) return text.len;
        if (self.vtable.width) |measure| return measure(self.ptr, text);

        var total: usize = 0;
        var rest = text;
        while (rest.len > 0) {
            const measured = self.next(rest);
            total += measured.cell_width;
            rest = rest[measured.byte_len..];
        }
        return total;
    }

    /// Deterministic byte geometry for non-terminal callers and legacy tests.
    pub const bytes: CellMetrics = .{ .ptr = &byte_context, .vtable = &byte_vtable };
    const byte_context: u8 = 0;
    const byte_vtable: VTable = .{ .next = byteNext };
    fn byteNext(_: *const anyopaque, text: []const u8) Measurement {
        return .{ .byte_len = if (text.len == 0) 0 else 1, .cell_width = if (text.len == 0) 0 else 1 };
    }
};

fn isNarrowAscii(text: []const u8) bool {
    var index: usize = 0;
    if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        while (index + vector_len <= text.len) : (index += vector_len) {
            const bytes: Vector = text[index..][0..vector_len].*;
            const special = (bytes < @as(Vector, @splat(0x20))) | (bytes >= @as(Vector, @splat(0x7f)));
            if (@reduce(.Or, special)) return false;
        }
    }
    for (text[index..]) |byte| if (byte < 0x20 or byte >= 0x7f) return false;
    return true;
}

test "width matches scalar measurement for every alignment and byte length" {
    var storage: [96]u8 = undefined;
    @memset(&storage, 'x');
    for (0..32) |offset| {
        for (0..65) |len| {
            const text = storage[offset .. offset + len];
            try std.testing.expectEqual(scalarWidth(CellMetrics.bytes, text), CellMetrics.bytes.width(text));
        }
    }
}

test "width keeps controls and UTF-8 on the adapter path" {
    const Counter = struct {
        width_calls: usize = 0,

        fn next(_: *const anyopaque, text: []const u8) Measurement {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
            return .{ .byte_len = @min(@as(usize, byte_len), text.len), .cell_width = if (text[0] < 0x20 or text[0] == 0x7f) 0 else 1 };
        }

        fn width(ptr: *const anyopaque, text: []const u8) usize {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ptr)));
            self.width_calls += 1;
            const metrics: CellMetrics = .{ .ptr = ptr, .vtable = &.{ .next = next } };
            return scalarWidth(metrics, text);
        }
    };

    var counter: Counter = .{};
    const metrics: CellMetrics = .{ .ptr = &counter, .vtable = &.{ .next = Counter.next, .width = Counter.width } };
    try std.testing.expectEqual(@as(usize, 5), metrics.width("plain"));
    try std.testing.expectEqual(@as(usize, 0), counter.width_calls);

    for ([_][]const u8{ "\x00", "\t", "\x7f", "e\xcc\x81", "\xe7\x95\x8c", "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb", "\xff" }) |text| {
        const before = counter.width_calls;
        try std.testing.expectEqual(scalarWidth(metrics, text), metrics.width(text));
        try std.testing.expectEqual(before + 1, counter.width_calls);
    }
}

fn scalarWidth(metrics: CellMetrics, text: []const u8) usize {
    var total: usize = 0;
    var rest = text;
    while (rest.len > 0) {
        const measured = metrics.next(rest);
        total += measured.cell_width;
        rest = rest[measured.byte_len..];
    }
    return total;
}
