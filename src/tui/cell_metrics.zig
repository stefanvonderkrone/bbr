//! Terminal-cell measurement seam used by every width-dependent projection.

pub const Measurement = struct {
    byte_len: usize,
    cell_width: usize,
};

pub const CellMetrics = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *const anyopaque, text: []const u8) Measurement,
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
