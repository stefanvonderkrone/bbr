const std = @import("std");
const keymap = @import("keymap.zig");
const theme = @import("theme.zig");

const testing = std.testing;

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []const u8,
    hint: ?[]const u8 = null,
};

pub const Configuration = struct {
    theme_name: []const u8,
    active_theme: theme.Theme,
    keymap: keymap.OwnedKeymap,

    pub fn deinit(self: *Configuration, allocator: std.mem.Allocator) void {
        allocator.free(self.theme_name);
        self.keymap.deinit(allocator);
    }
};

pub const Result = union(enum) {
    ok: Configuration,
    invalid: []Diagnostic,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*configuration| configuration.deinit(allocator),
            .invalid => |diagnostics| allocator.free(diagnostics),
        }
        self.* = undefined;
    }
};

pub fn defaults(allocator: std.mem.Allocator) !Configuration {
    return .{
        .theme_name = try allocator.dupe(u8, "system"),
        .active_theme = theme.system,
        .keymap = try keymap.Keymap.fromOverrides(allocator, &.{}),
    };
}

pub fn path(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_CONFIG_HOME")) |base| return try std.fmt.allocPrint(allocator, "{s}/bbr/config.toml", .{base});
    if (env.get("HOME")) |home| return try std.fmt.allocPrint(allocator, "{s}/.config/bbr/config.toml", .{home});
    return null;
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Result {
    if (source.len > 64 * 1024) {
        const diagnostics = try allocator.alloc(Diagnostic, 1);
        diagnostics[0] = .{ .line = 1, .column = 1, .message = "configuration exceeds 64 KiB", .hint = "remove unused entries or comments" };
        return .{ .invalid = diagnostics };
    }

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);
    var overrides: std.ArrayList(keymap.Override) = .empty;
    defer overrides.deinit(allocator);
    var override_lines: std.ArrayList(usize) = .empty;
    defer override_lines.deinit(allocator);
    var theme_name: []const u8 = "system";
    var theme_seen = false;
    var section: enum { root, keymap, unknown } = .root;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        var parser = LineParser{ .text = raw_line };
        parser.space();
        if (parser.done() or parser.peek() == '#') continue;
        if (parser.peek() == '[') {
            const parsed_section = parser.section() catch {
                try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "malformed table header", .hint = "use [keymap]" });
                section = .unknown;
                continue;
            };
            parser.space();
            if (!parser.trailing()) try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "unexpected text after table header" });
            if (std.mem.eql(u8, parsed_section, "keymap")) section = .keymap else {
                section = .unknown;
                try diagnostics.append(allocator, .{ .line = line_number, .column = 2, .message = "unknown table", .hint = "the only table is [keymap]" });
            }
            continue;
        }

        const key = parser.key() catch {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a key" });
            continue;
        };
        parser.space();
        if (!parser.take('=')) {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected '=' after key" });
            continue;
        }
        parser.space();
        const value = parser.quoted() catch {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "expected a quoted string value" });
            continue;
        };
        parser.space();
        if (!parser.trailing()) {
            try diagnostics.append(allocator, .{ .line = line_number, .column = parser.column(), .message = "unexpected text after value" });
            continue;
        }

        switch (section) {
            .root => if (std.mem.eql(u8, key, "theme")) {
                if (theme_seen) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate 'theme' key", .hint = "keep exactly one top-level theme entry" });
                } else if (!isThemeName(value)) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown Theme name", .hint = "use system, dark, light, Catppuccin, Gruvbox, or Solarized" });
                } else theme_name = value;
                theme_seen = true;
            } else try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "unknown top-level key", .hint = "did you mean 'theme'?" }),
            .keymap => {
                if (overrides.items.len == 256) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "more than 256 Keymap entries" });
                    continue;
                }
                const override: keymap.Override = .{ .sequence = key, .action = value };
                keymap.validateOverride(override) catch |err| {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = switch (err) {
                        error.UnknownAction => "unknown Action name",
                        error.UnknownKey => "unknown key name",
                        error.SequenceTooLong => "key sequence exceeds eight chords",
                        error.CountConflict => "key sequence cannot begin with a Count digit",
                        else => "invalid key sequence",
                    }, .hint = switch (err) {
                        error.UnknownAction => "use a kebab-case Action name shown in the Keybindings Overlay",
                        error.UnknownKey => "use a printable key or a documented named key such as page-down",
                        else => null,
                    } });
                    continue;
                };
                var duplicate = false;
                for (overrides.items) |existing| {
                    duplicate = (try keymap.sequenceConflict(existing.sequence, override.sequence)) == .duplicate;
                    if (duplicate) break;
                }
                if (duplicate) {
                    try diagnostics.append(allocator, .{ .line = line_number, .column = 1, .message = "duplicate Keymap chord", .hint = "keep exactly one entry for each chord sequence" });
                    continue;
                }
                try overrides.append(allocator, override);
                try override_lines.append(allocator, line_number);
            },
            .unknown => {},
        }
    }

    var owned_keymap = keymap.Keymap.fromOverrides(allocator, overrides.items) catch |err| {
        try diagnostics.append(allocator, .{ .line = if (override_lines.getLastOrNull()) |line| line else 1, .column = 1, .message = switch (err) {
            error.PrefixConflict => "a key sequence is the prefix of another binding",
            else => "Keymap could not be materialized",
        }, .hint = "remove one binding, unbind the conflicting default, or choose distinct prefixes" });
        return .{ .invalid = try diagnostics.toOwnedSlice(allocator) };
    };
    errdefer owned_keymap.deinit(allocator);
    if (diagnostics.items.len > 0) {
        owned_keymap.deinit(allocator);
        return .{ .invalid = try diagnostics.toOwnedSlice(allocator) };
    }
    return .{ .ok = .{ .theme_name = try allocator.dupe(u8, theme_name), .active_theme = theme.byName(theme_name).?, .keymap = owned_keymap } };
}

test "strict configuration rejects duplicate keys and sequence prefixes together" {
    const source =
        \\theme = "dark"
        \\theme = "light"
        \\[keymap]
        \\"space r" = "reply"
        \\"space r c" = "comment"
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .invalid);
    try testing.expectEqual(@as(usize, 2), result.invalid.len);
    try testing.expectEqual(@as(usize, 2), result.invalid[0].line);
    try testing.expectEqual(@as(usize, 5), result.invalid[1].line);
}

test "unbinding a default can free its Leader for a shorter Action" {
    const source =
        \\[keymap]
        \\"g g" = "none"
        \\"g" = "to-top"
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
}

fn isThemeName(name: []const u8) bool {
    return theme.byName(name) != null;
}

const LineParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn done(self: LineParser) bool {
        return self.pos >= self.text.len;
    }
    fn peek(self: LineParser) u8 {
        return self.text[self.pos];
    }
    fn column(self: LineParser) usize {
        return self.pos + 1;
    }
    fn take(self: *LineParser, expected: u8) bool {
        if (self.done() or self.peek() != expected) return false;
        self.pos += 1;
        return true;
    }
    fn space(self: *LineParser) void {
        while (!self.done() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\r')) self.pos += 1;
    }
    fn trailing(self: LineParser) bool {
        return self.done() or self.peek() == '#';
    }
    fn section(self: *LineParser) ![]const u8 {
        if (!self.take('[')) return error.ExpectedSection;
        const start = self.pos;
        while (!self.done() and self.peek() != ']') self.pos += 1;
        if (self.done() or self.pos == start) return error.ExpectedClose;
        const value = self.text[start..self.pos];
        self.pos += 1;
        return value;
    }
    fn key(self: *LineParser) ![]const u8 {
        if (!self.done() and self.peek() == '"') return self.quoted();
        const start = self.pos;
        while (!self.done()) {
            const ch = self.peek();
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.ExpectedKey;
        return self.text[start..self.pos];
    }
    fn quoted(self: *LineParser) ![]const u8 {
        if (!self.take('"')) return error.ExpectedQuote;
        const start = self.pos;
        while (!self.done() and self.peek() != '"') {
            if (self.peek() == '\\') return error.UnsupportedEscape;
            self.pos += 1;
        }
        if (self.done()) return error.UnterminatedString;
        const value = self.text[start..self.pos];
        self.pos += 1;
        return value;
    }
};

test "configuration resolves theme and keymap while collecting independent diagnostics" {
    const source =
        \\theme = "catppuccin-mocha"
        \\[keymap]
        \\"ctrl-d" = "page-down"
        \\"q" = "none"
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
    try testing.expectEqualStrings("catppuccin-mocha", result.ok.theme_name);

    const broken =
        \\theem = "dark"
        \\theme = "midnight"
        \\[keymap]
        \\"ctrl-d" = "fly"
    ;
    var invalid = try parse(testing.allocator, broken);
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid == .invalid);
    try testing.expectEqual(@as(usize, 3), invalid.invalid.len);
    try testing.expectEqual(@as(usize, 1), invalid.invalid[0].line);
}

test "configuration path prefers XDG and falls back to HOME" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/ada");
    const home_path = (try path(testing.allocator, &env)).?;
    defer testing.allocator.free(home_path);
    try testing.expectEqualStrings("/home/ada/.config/bbr/config.toml", home_path);

    try env.put("XDG_CONFIG_HOME", "/cfg");
    const xdg_path = (try path(testing.allocator, &env)).?;
    defer testing.allocator.free(xdg_path);
    try testing.expectEqualStrings("/cfg/bbr/config.toml", xdg_path);
}
