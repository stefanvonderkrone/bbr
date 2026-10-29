//! Best-effort Atlassian fixture mappings. See emoji-fixture/README.md.
const std = @import("std");
const catalog = std.StaticStringMap([]const u8).initComptime(@import("emoji_data.zig").entries);
const displayed = blk: {
    @setEvalBranchQuota(500_000);
    var values: [catalog.values().len][]const u8 = undefined;
    for (catalog.values(), 0..) |fallback, index| values[index] = emojiStyle(fallback);
    break :blk values;
};

pub const Match = struct { text: []const u8, fallback: []const u8, name: []const u8, authored_len: usize };

pub fn at(text: []const u8) ?Match {
    if (text.len == 0 or text[0] != ':') return null;
    const close = std.mem.indexOfScalarPos(u8, text, 1, ':') orelse return null;
    const end = close + 1;
    // Prefer the complete listed compound name to its base emoji.
    if (std.mem.startsWith(u8, text[end..], ":skin-tone-")) {
        if (std.mem.indexOfScalarPos(u8, text, end + 1, ':')) |compound_close| {
            if (catalog.getIndex(text[0 .. compound_close + 1])) |index|
                return match(index, compound_close + 1);
        }
    }
    const index = catalog.getIndex(text[0..end]) orelse return null;
    return match(index, end);
}

fn match(index: usize, authored_len: usize) Match {
    return .{ .text = displayed[index], .fallback = catalog.values()[index], .name = catalog.keys()[index], .authored_len = authored_len };
}

/// Consume only metadata that proves it describes the preceding catalog emoji.
pub fn metadataLen(text: []const u8, converted: Match) usize {
    if (!std.mem.startsWith(u8, text, "{:")) return 0;
    var pos: usize = 2;
    var id: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    while (pos < text.len) {
        const before = pos;
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) pos += 1;
        if (pos == text.len) return 0;
        if (text[pos] == '}') {
            if (!matchesId(id orelse return 0, converted.fallback)) return 0;
            if (label) |value| if (!std.mem.eql(u8, value, converted.fallback) and !std.mem.eql(u8, value, converted.text)) return 0;
            return pos + 1;
        }
        if (pos == before) return 0;
        const start = pos;
        while (pos < text.len and (std.ascii.isAlphabetic(text[pos]) or text[pos] == '-')) pos += 1;
        const name = text[start..pos];
        if (pos + 1 >= text.len or text[pos] != '=') return 0;
        pos += 1;
        const quote = text[pos];
        if (quote != '\'' and quote != '"') return 0;
        pos += 1;
        const value_start = pos;
        while (pos < text.len and text[pos] != quote) : (pos += 1) {
            if (text[pos] == '\r' or text[pos] == '\n') return 0;
        }
        if (pos == text.len) return 0;
        const value = text[value_start..pos];
        pos += 1;
        if (std.mem.eql(u8, name, "data-emoji-id") and id == null) {
            id = value;
        } else if (std.mem.eql(u8, name, "data-emoji-text") and label == null) {
            label = value;
        } else return 0;
    }
    return 0;
}

fn matchesId(id: []const u8, fallback: []const u8) bool {
    var parts = std.mem.splitScalar(u8, id, '-');
    var scalars = std.unicode.Utf8View.initUnchecked(fallback).iterator();
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 6) return false;
        for (part) |byte| if (!std.ascii.isHex(byte)) return false;
        const scalar = std.fmt.parseInt(u21, part, 16) catch return false;
        if (scalar != (scalars.nextCodepoint() orelse return false)) return false;
    }
    return scalars.nextCodepoint() == null;
}

fn emojiStyle(comptime fallback: []const u8) []const u8 {
    var iterator = std.unicode.Utf8View.initComptime(fallback).iterator();
    const codepoint = iterator.nextCodepoint() orelse return fallback;
    // Existing selectors, skin tones, keycaps, flags, and joined sequences stay intact.
    if (iterator.nextCodepoint() != null) return fallback;
    // Unicode 16.0 emoji-style variation bases with Emoji_Presentation=No.
    // https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-variation-sequences.txt
    // https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt
    return switch (codepoint) {
        0x23,
        0x2a,
        0x30...0x39,
        0xa9,
        0xae,
        0x203c,
        0x2049,
        0x2122,
        0x2139,
        0x2194...0x2199,
        0x21a9...0x21aa,
        0x2328,
        0x23cf,
        0x23ed...0x23ef,
        0x23f1...0x23f2,
        0x23f8...0x23fa,
        0x24c2,
        0x25aa...0x25ab,
        0x25b6,
        0x25c0,
        0x25fb...0x25fc,
        0x2600...0x2604,
        0x260e,
        0x2611,
        0x2618,
        0x261d,
        0x2620,
        0x2622...0x2623,
        0x2626,
        0x262a,
        0x262e...0x262f,
        0x2638...0x263a,
        0x2640,
        0x2642,
        0x265f...0x2660,
        0x2663,
        0x2665...0x2666,
        0x2668,
        0x267b,
        0x267e,
        0x2692,
        0x2694...0x2697,
        0x2699,
        0x269b...0x269c,
        0x26a0,
        0x26a7,
        0x26b0...0x26b1,
        0x26c8,
        0x26cf,
        0x26d1,
        0x26d3,
        0x26e9,
        0x26f0...0x26f1,
        0x26f4,
        0x26f7...0x26f9,
        0x2702,
        0x2708...0x2709,
        0x270c...0x270d,
        0x270f,
        0x2712,
        0x2714,
        0x2716,
        0x271d,
        0x2721,
        0x2733...0x2734,
        0x2744,
        0x2747,
        0x2763...0x2764,
        0x27a1,
        0x2934...0x2935,
        0x2b05...0x2b07,
        0x3030,
        0x303d,
        0x3297,
        0x3299,
        0x1f170...0x1f171,
        0x1f17e...0x1f17f,
        0x1f202,
        0x1f237,
        0x1f321,
        0x1f324...0x1f32c,
        0x1f336,
        0x1f37d,
        0x1f396...0x1f397,
        0x1f399...0x1f39b,
        0x1f39e...0x1f39f,
        0x1f3cb...0x1f3ce,
        0x1f3d4...0x1f3df,
        0x1f3f3,
        0x1f3f5,
        0x1f3f7,
        0x1f43f,
        0x1f441,
        0x1f4fd,
        0x1f549...0x1f54a,
        0x1f56f...0x1f570,
        0x1f573...0x1f579,
        0x1f587,
        0x1f58a...0x1f58d,
        0x1f590,
        0x1f5a5,
        0x1f5a8,
        0x1f5b1...0x1f5b2,
        0x1f5bc,
        0x1f5c2...0x1f5c4,
        0x1f5d1...0x1f5d3,
        0x1f5dc...0x1f5de,
        0x1f5e1,
        0x1f5e3,
        0x1f5e8,
        0x1f5ef,
        0x1f5f3,
        0x1f5fa,
        0x1f6cb,
        0x1f6cd...0x1f6cf,
        0x1f6e0...0x1f6e5,
        0x1f6e9,
        0x1f6f0,
        0x1f6f3,
        => fallback ++ "\u{fe0f}",
        else => fallback,
    };
}

test "M23 emoji prefers supported emoji-style symbols and retains compound fixture bytes" {
    for ([_]struct { name: []const u8, display: []const u8 }{
        .{ .name = ":heart:", .display = "❤️" },
        .{ .name = ":sunny:", .display = "☀️" },
        .{ .name = ":cloud:", .display = "☁️" },
        .{ .name = ":warning:", .display = "⚠️" },
        .{ .name = ":airplane:", .display = "✈️" },
        .{ .name = ":desktop:", .display = "🖥️" },
        .{ .name = ":white_check_mark:", .display = "✅" },
        .{ .name = ":mask:", .display = "😷" },
        .{ .name = ":one:", .display = "1️⃣" },
        .{ .name = ":flag_de:", .display = "🇩🇪" },
        .{ .name = ":thumbsup::skin-tone-2:", .display = "👍🏻" },
        .{ .name = ":woman_technologist::skin-tone-2:", .display = "👩🏻‍💻" },
    }) |example| try std.testing.expectEqualStrings(example.display, at(example.name).?.text);
    try std.testing.expectEqualStrings("❤", at(":heart:").?.fallback);
    try std.testing.expectEqualStrings("❤\u{fe0e}", emojiStyle("❤\u{fe0e}"));
    try std.testing.expectEqualStrings("❤️", emojiStyle("❤️"));
}
