//! Public account lookup by Atlassian account ID or Bitbucket UUID.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");

pub const get_help =
    \\usage: bbr api get-user --user-id ID [--json]
    \\
    \\Get public account information (GET /users/{user_id}).
    \\Accept an Atlassian account ID or a Bitbucket UUID, including UUID braces.
    \\Return the UUID, account ID, display name, and nickname.
    \\This lookup does not depend on Workspace membership.
    \\
;

pub fn parseUserId(args: []const []const u8) ![]const u8 {
    var cur: arg.Cursor = .{ .args = args };
    var user_id: ?[]const u8 = null;
    while (cur.next()) |value| {
        const flag = arg.splitFlag(value) orelse return error.UnknownFlag;
        if (!std.mem.eql(u8, flag.name, "user-id")) return error.UnknownFlag;
        try arg.setOption([]const u8, &user_id, try arg.takeValue(&cur, flag));
    }
    const id = user_id orelse return error.MissingRequired;
    if (std.mem.trim(u8, id, " \t\r\n").len == 0) return error.BadRequest;
    return id;
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const user_id = try parseUserId(args);
    const user = try bb.getUser(init.gpa, user_id);
    defer bbr.bitbucket.deinitUser(init.gpa, user);
    if (json) return out.printJson(init, user);
    try out.printLine(init, "{s} {s}", .{ user.uuid, user.display_name });
    try out.printLine(init, "account_id: {s}", .{user.account_id});
    try out.printLine(init, "nickname: {s}", .{user.nickname});
}

test "get-user accepts account IDs and UUIDs and rejects incomplete or conflicting options" {
    const testing = std.testing;
    try testing.expectEqualStrings("account-id", try parseUserId(&.{ "--user-id", "account-id" }));
    try testing.expectEqualStrings("{uuid}", try parseUserId(&.{"--user-id={uuid}"}));
    try testing.expectEqualStrings("id", try parseUserId(&.{ "--user-id=id", "--user-id=id" }));
    try testing.expectError(error.MissingRequired, parseUserId(&.{}));
    try testing.expectError(error.MissingValue, parseUserId(&.{"--user-id"}));
    try testing.expectError(error.BadRequest, parseUserId(&.{"--user-id="}));
    try testing.expectError(error.BadRequest, parseUserId(&.{"--user-id=  "}));
    try testing.expectError(error.BadRequest, parseUserId(&.{ "--user-id=a", "--user-id=b" }));
    try testing.expectError(error.UnknownFlag, parseUserId(&.{"--uuid=id"}));
    try testing.expectError(error.UnknownFlag, parseUserId(&.{"id"}));
}
