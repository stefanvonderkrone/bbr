//! Bitbucket Cloud credential, read from the environment. Zig 0.16 removed
//! `std.process.getEnvVarOwned`; env access now goes through the
//! `std.process.Environ.Map` the runtime hands `main` via `Init.environ_map`.
//!
//! The token is a secret: it is never logged and never persisted. It lives only
//! in the environ map (process lifetime) and in the Authorization header we build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

pub const Credential = struct {
    username: []const u8,
    token: []const u8,
    workspace: []const u8,

    pub const Error = error{
        MissingUsername,
        MissingToken,
        MissingWorkspace,
    };

    /// Borrows slices from `env` (valid for the process lifetime); no copies.
    pub fn fromEnv(env: *const EnvMap) Error!Credential {
        return .{
            .username = env.get("BITBUCKET_USERNAME") orelse return error.MissingUsername,
            .token = env.get("BITBUCKET_TOKEN") orelse return error.MissingToken,
            .workspace = env.get("BITBUCKET_WORKSPACE") orelse return error.MissingWorkspace,
        };
    }

    /// Build `Basic base64(username:token)`. Result owned by `allocator`.
    /// Keep the lifetime short and never log it — it embeds the token.
    pub fn basicAuthHeader(self: Credential, allocator: Allocator) ![]u8 {
        const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.username, self.token });
        defer allocator.free(raw);

        const enc = std.base64.standard.Encoder;
        const out = try allocator.alloc(u8, "Basic ".len + enc.calcSize(raw.len));
        @memcpy(out[0.."Basic ".len], "Basic ");
        _ = enc.encode(out["Basic ".len..], raw);
        return out;
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;

fn envWith(map: *EnvMap, pairs: []const [2][]const u8) !void {
    for (pairs) |p| try map.put(p[0], p[1]);
}

test "fromEnv reads all three variables" {
    var map = EnvMap.init(testing.allocator);
    defer map.deinit();
    try envWith(&map, &.{
        .{ "BITBUCKET_USERNAME", "ada" },
        .{ "BITBUCKET_TOKEN", "secret" },
        .{ "BITBUCKET_WORKSPACE", "check24" },
    });

    const c = try Credential.fromEnv(&map);
    try testing.expectEqualStrings("ada", c.username);
    try testing.expectEqualStrings("secret", c.token);
    try testing.expectEqualStrings("check24", c.workspace);
}

test "fromEnv reports the specific missing variable" {
    var map = EnvMap.init(testing.allocator);
    defer map.deinit();
    try envWith(&map, &.{
        .{ "BITBUCKET_USERNAME", "ada" },
        .{ "BITBUCKET_TOKEN", "secret" },
    });
    try testing.expectError(error.MissingWorkspace, Credential.fromEnv(&map));
}

test "basicAuthHeader is Basic base64(user:token)" {
    const a = testing.allocator;
    const c: Credential = .{ .username = "u", .token = "t", .workspace = "w" };
    const header = try c.basicAuthHeader(a);
    defer a.free(header);
    try testing.expectEqualStrings("Basic dTp0", header);
}
