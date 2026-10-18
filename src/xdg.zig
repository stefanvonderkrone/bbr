//! XDG base directories. This module is the only reader of `XDG_CONFIG_HOME`,
//! `XDG_DATA_HOME`, and `XDG_STATE_HOME`, and `tools/check_xdg_reads.py` fails on any other
//! reader. The XDG Base Directory spec says to ignore an empty or relative
//! base, so a value like `relative/dir` never makes bbr read or create files
//! under the working directory. The `HOME` fallback follows the same rule.

const std = @import("std");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

/// `$XDG_CONFIG_HOME`, else `$HOME/.config`, else `null`. Caller owns the result.
pub fn configHome(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    return home(allocator, env, "XDG_CONFIG_HOME", ".config");
}

/// `$XDG_DATA_HOME`, else `$HOME/.local/share`, else `null`. Caller owns the result.
pub fn dataHome(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    return home(allocator, env, "XDG_DATA_HOME", ".local/share");
}

/// `$XDG_STATE_HOME`, else `$HOME/.local/state`, else `null`. Caller owns the result.
pub fn stateHome(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    return home(allocator, env, "XDG_STATE_HOME", ".local/state");
}

/// Path of bbr's `config.toml`, or `null` when no config home resolves.
/// Caller owns the result.
pub fn configFile(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    const base = (try configHome(allocator, env)) orelse return null;
    defer allocator.free(base);
    return try std.fmt.allocPrint(allocator, "{s}/bbr/config.toml", .{base});
}

fn home(allocator: Allocator, env: *const EnvMap, variable: []const u8, fallback: []const u8) !?[]u8 {
    if (env.get(variable)) |base| if (std.fs.path.isAbsolute(base)) return try allocator.dupe(u8, base);
    const user_home = env.get("HOME") orelse return null;
    if (!std.fs.path.isAbsolute(user_home)) return null;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ user_home, fallback });
}

const testing = std.testing;

fn expectResolved(expected: ?[]const u8, resolved: ?[]u8) !void {
    defer if (resolved) |value| testing.allocator.free(value);
    if (expected) |value| return testing.expectEqualStrings(value, resolved orelse return error.TestExpectedEqual);
    try testing.expect(resolved == null);
}

test "an absolute XDG base wins over HOME" {
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/ada");
    try env.put("XDG_CONFIG_HOME", "/cfg");
    try env.put("XDG_DATA_HOME", "/data");
    try env.put("XDG_STATE_HOME", "/state");
    try expectResolved("/cfg", try configHome(testing.allocator, &env));
    try expectResolved("/data", try dataHome(testing.allocator, &env));
    try expectResolved("/state", try stateHome(testing.allocator, &env));
    try expectResolved("/cfg/bbr/config.toml", try configFile(testing.allocator, &env));
}

test "an unset, empty, or relative XDG base falls back to HOME" {
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/ada");
    try expectResolved("/home/ada/.config", try configHome(testing.allocator, &env));
    try expectResolved("/home/ada/.local/share", try dataHome(testing.allocator, &env));
    try expectResolved("/home/ada/.local/state", try stateHome(testing.allocator, &env));
    for ([_][]const u8{ "", "relative/dir", "./dir" }) |base| {
        try env.put("XDG_CONFIG_HOME", base);
        try env.put("XDG_DATA_HOME", base);
        try env.put("XDG_STATE_HOME", base);
        try expectResolved("/home/ada/.config", try configHome(testing.allocator, &env));
        try expectResolved("/home/ada/.local/share", try dataHome(testing.allocator, &env));
        try expectResolved("/home/ada/.local/state", try stateHome(testing.allocator, &env));
        try expectResolved("/home/ada/.config/bbr/config.toml", try configFile(testing.allocator, &env));
    }
}

test "no usable XDG base and no HOME resolve to null" {
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try expectResolved(null, try configHome(testing.allocator, &env));
    try expectResolved(null, try dataHome(testing.allocator, &env));
    try expectResolved(null, try stateHome(testing.allocator, &env));
    try expectResolved(null, try configFile(testing.allocator, &env));
    try env.put("XDG_CONFIG_HOME", "relative");
    try env.put("XDG_DATA_HOME", "");
    try env.put("XDG_STATE_HOME", "./state");
    try expectResolved(null, try configHome(testing.allocator, &env));
    try expectResolved(null, try dataHome(testing.allocator, &env));
    try expectResolved(null, try stateHome(testing.allocator, &env));
}

test "an empty or relative HOME gives no fallback" {
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "", "relative/home", "./home" }) |user_home| {
        try env.put("HOME", user_home);
        try expectResolved(null, try configHome(testing.allocator, &env));
        try expectResolved(null, try dataHome(testing.allocator, &env));
        try expectResolved(null, try stateHome(testing.allocator, &env));
        try expectResolved(null, try configFile(testing.allocator, &env));
    }
    try env.put("XDG_DATA_HOME", "/data");
    try expectResolved("/data", try dataHome(testing.allocator, &env));
}
