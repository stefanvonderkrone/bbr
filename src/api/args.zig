//! Shared argument parsing for `bbr api` verbs. Manual parsing (the repo has
//! no arg library): long `--kebab-case` flags only, supporting both
//! `--flag value` and `--flag=value`. No short aliases in v1.

const std = @import("std");

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    MissingRequired,
    InvalidNumber,
};

/// Minimal cursor over an arg slice.
pub const Cursor = struct {
    args: []const []const u8,
    pos: usize = 0,

    pub fn next(self: *Cursor) ?[]const u8 {
        if (self.pos >= self.args.len) return null;
        const v = self.args[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn peek(self: *const Cursor) ?[]const u8 {
        if (self.pos >= self.args.len) return null;
        return self.args[self.pos];
    }

    pub fn done(self: *const Cursor) bool {
        return self.pos >= self.args.len;
    }
};

/// A parsed `--flag [value]` pair. `value` is null for booleans.
pub const Flag = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Split `--name=value` into name + value; bare `--name` has null value and
/// consumes the next arg only when the caller wants a value.
pub fn splitFlag(arg: []const u8) ?Flag {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const bare = arg[2..];
    if (bare.len == 0) return null;
    if (std.mem.indexOfScalar(u8, bare, '=')) |eq| {
        return .{ .name = bare[0..eq], .value = bare[eq + 1 ..] };
    }
    return .{ .name = bare, .value = null };
}

/// Take the value for a known value-flag: either the `=value` suffix or the
/// next arg. Errors when absent.
pub fn takeValue(cur: *Cursor, flag: Flag) ParseError![]const u8 {
    if (flag.value) |v| return v;
    return cur.next() orelse return error.MissingValue;
}

/// True for `--help` / `-h` (only long `--help` is canonical; `-h` accepted
/// as a convenience in help detection only).
pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn parseU64(s: []const u8) ParseError!u64 {
    return std.fmt.parseInt(u64, s, 10) catch return error.InvalidNumber;
}

pub fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch return error.InvalidNumber;
}

pub fn parseUsize(s: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, s, 10) catch return error.InvalidNumber;
}

test "splitFlag handles = and bare forms" {
    const a = splitFlag("--repository=foo").?;
    try std.testing.expectEqualStrings("repository", a.name);
    try std.testing.expectEqualStrings("foo", a.value.?);
    const b = splitFlag("--json").?;
    try std.testing.expectEqualStrings("json", b.name);
    try std.testing.expect(b.value == null);
    try std.testing.expect(splitFlag("get-pull-request") == null);
}

test "takeValue consumes next arg" {
    const args = [_][]const u8{"myrepo"};
    var cur: Cursor = .{ .args = &args };
    const v = try takeValue(&cur, .{ .name = "repository", .value = null });
    try std.testing.expectEqualStrings("myrepo", v);
}
