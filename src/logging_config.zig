const std = @import("std");
const source = @import("config_source.zig");
pub const Result = union(enum) { enabled: bool, invalid: usize };

pub fn parse(text: []const u8) Result {
    if (text.len > source.max_bytes) return .{ .invalid = 1 };
    var in_logging = false;
    var table_seen = false;
    var key_seen = false;
    var enabled_value = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line: usize = 0;
    while (lines.next()) |raw| {
        line += 1;
        var parser: source.LineParser = .{ .text = raw };
        parser.space();
        if (parser.done() or parser.peek() == '#') continue;
        if (parser.peek() == '[') {
            const section = parser.section() catch |err| switch (err) {
                error.ExpectedClose, error.ExpectedSection => return .{ .invalid = line },
            };
            parser.space();
            if (!parser.trailing()) return .{ .invalid = line };
            in_logging = std.mem.eql(u8, section, "logging");
            if (in_logging) {
                if (table_seen) return .{ .invalid = line };
                table_seen = true;
            }
        } else if (in_logging) {
            const key = parser.key() catch return .{ .invalid = line };
            if (!std.mem.eql(u8, key, "enabled") or key_seen) return .{ .invalid = line };
            key_seen = true;
            parser.space();
            if (!parser.take('=')) return .{ .invalid = line };
            parser.space();
            const value = parser.boolean() catch |err| switch (err) {
                error.ExpectedBoolean => return .{ .invalid = line },
            };
            parser.space();
            if (!parser.trailing()) return .{ .invalid = line };
            enabled_value = std.mem.eql(u8, value, "true");
        }
    }
    return .{ .enabled = enabled_value };
}

pub fn enabled(snapshot: source.Snapshot) bool {
    if (snapshot.read_error != null) return false;
    return switch (parse(snapshot.source orelse "")) {
        .enabled => |value| value,
        .invalid => false,
    };
}

test "diagnostics logging config has one strict policy independent of TUI values" {
    const testing = std.testing;
    try testing.expect(!parse("").enabled);
    try testing.expect(parse("theme = 99\n[keymap]\nunknown = 9\n[logging]\nenabled = true # consent").enabled);
    for ([_][]const u8{
        "[logging]\nenabled = \"true\"",              "[logging]\nenabled = trueish",
        "[logging]\nenabled = true\nenabled = false", "[logging]\nextra = true",
        "[logging]\nenabled = true\n[logging]",       "[broken\n[logging]\nenabled = true",
    }) |text| try testing.expect(parse(text) == .invalid);
}
