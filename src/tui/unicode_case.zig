//! Shared simple Unicode case folding for search and reference names.

const std = @import("std");
const data = @import("search_unicode_data.zig");

pub fn fold(scalar: u21) u21 {
    if (scalar < 0x80) return if (scalar >= 'A' and scalar <= 'Z') scalar + ('a' - 'A') else scalar;
    var low: usize = 0;
    var high = data.folds.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const mapping = data.folds[middle];
        if (scalar < mapping.source) high = middle else if (scalar > mapping.source) low = middle + 1 else return mapping.target;
    }
    return scalar;
}

pub fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    const left_view = std.unicode.Utf8View.init(left) catch return std.mem.eql(u8, left, right);
    const right_view = std.unicode.Utf8View.init(right) catch return false;
    var a = left_view.iterator();
    var b = right_view.iterator();
    while (a.nextCodepoint()) |scalar| {
        if (fold(scalar) != fold(b.nextCodepoint() orelse return false)) return false;
    }
    return b.nextCodepoint() == null;
}
