//! Best-effort Atlassian fixture mappings. See emoji-fixture/README.md.
const std = @import("std");
const catalog = std.StaticStringMap([]const u8).initComptime(@import("emoji_data.zig").entries);

pub const Match = struct { text: []const u8, name: []const u8, authored_len: usize };

pub fn at(text: []const u8) ?Match {
    if (text.len == 0 or text[0] != ':') return null;
    const close = std.mem.indexOfScalarPos(u8, text, 1, ':') orelse return null;
    const end = close + 1;
    // Prefer the complete listed compound name to its base emoji.
    if (std.mem.startsWith(u8, text[end..], ":skin-tone-")) {
        if (std.mem.indexOfScalarPos(u8, text, end + 1, ':')) |compound_close| {
            if (catalog.getIndex(text[0 .. compound_close + 1])) |index|
                return .{ .text = catalog.values()[index], .name = catalog.keys()[index], .authored_len = compound_close + 1 };
        }
    }
    const index = catalog.getIndex(text[0..end]) orelse return null;
    return .{ .text = catalog.values()[index], .name = catalog.keys()[index], .authored_len = end };
}
