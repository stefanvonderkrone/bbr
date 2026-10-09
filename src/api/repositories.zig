//! `bbr api list-repositories | get-repository`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const list_help =
    \\usage: bbr api list-repositories [--workspace SLUG] [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List repositories in a workspace (GET /repositories/{workspace}).
    \\Workspace defaults to BITBUCKET_WORKSPACE.
    \\
;

pub const get_help =
    \\usage: bbr api get-repository --repository SLUG [--workspace SLUG] [--json]
    \\
    \\Get one repository (GET /repositories/{workspace}/{repository}).
    \\
;

const ListArgs = struct {
    workspace: ?[]const u8,
    page: bbr.bitbucket.PageOptions,
};

fn parseList(args: []const []const u8) !ListArgs {
    var cur: arg.Cursor = .{ .args = args };
    var workspace: ?[]const u8 = null;
    var page: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (try ws.takePageFlag(&cur, f, &page)) continue;
        if (std.mem.eql(u8, f.name, "workspace")) {
            _ = cur.next();
            workspace = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    return .{ .workspace = workspace, .page = page };
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const parsed = try parseList(args);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const items = try bb.listRepositories(arena.allocator(), parsed.workspace, parsed.page);
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |r| try out.printLine(init, "{s} ({s})", .{ r.slug, r.full_name });
        try out.printLine(init, "ok: {d} repositor(ies)", .{items.len});
    }
}

test "repository list flags can interleave workspace and page controls" {
    const parsed = try parseList(&.{ "--page=3", "--workspace", "demo", "--query=slug=\"repo\"", "--pagelen=10", "--sort=-slug", "--limit=12", "--no-follow" });
    try std.testing.expectEqualStrings("demo", parsed.workspace.?);
    try std.testing.expectEqual(@as(u32, 3), parsed.page.page.?);
    try std.testing.expectEqual(@as(u32, 10), parsed.page.pagelen.?);
    try std.testing.expectEqual(@as(usize, 12), parsed.page.limit.?);
    try std.testing.expectEqualStrings("slug=\"repo\"", parsed.page.query.?);
    try std.testing.expectEqualStrings("-slug", parsed.page.sort.?);
    try std.testing.expect(!parsed.page.follow);
    try std.testing.expectError(error.UnknownFlag, parseList(&.{ "--workspace=demo", "--no-follow=false" }));
    try std.testing.expectError(error.InvalidNumber, parseList(&.{ "--page=0", "--workspace=demo" }));
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var workspace: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "workspace")) {
            _ = cur.next();
            workspace = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const r = try bb.getRepository(arena.allocator(), repo, workspace);
    if (json) {
        try out.printJson(init, r);
    } else {
        try out.printLine(init, "{s} ({s}) private={}", .{ r.slug, r.full_name, r.is_private });
        try out.printLine(init, "name: {s}", .{r.name});
        try out.printLine(init, "uuid: {s}", .{r.uuid});
    }
}
